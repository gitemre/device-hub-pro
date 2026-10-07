import XCTest
@testable import DeviceHubProKit

/// A physical iPhone's Controls: the Controls commands of
/// `DevicectlPhysicalClient`, the capability-driven routing and
/// `ApplePhysicalControlsBackend`, fed real captures.
///
/// The `devicectl-…` fixtures this phase added under `Fixtures/ios27-device/`
/// (info-appearance-baseline, info-appearance-dark, info-appearance-grayscale,
/// settings-appearance-* , settings-voiceover-enable, settings-voiceover-disable,
/// info-voiceover-on, orientation-get, orientation-set-landscapeLeft,
/// simulate-location-coordinate, simulate-location-clear,
/// process-sendMemoryWarning, pasteboard-copy, pasteboard-paste and the
/// pasteboard-paste stdout text) are byte-exact captures of devicectl 642.16
/// (CoreDevice 642.16, JSON version 5, Xcode 27.0) from the dedicated
/// test iPhone (an iPhone 12 on iOS 27.0), taken on 2026-09-29, each setting
/// changed and put back (`ApplePhysicalControlsLiveTests`). They carry the
/// same-length placeholders of the fixtures (see
/// `ApplePhysicalDeviceTests`) and two more in the path of the pasteboard
/// file: the macOS user name, `aqauser001`, and the capturing session's
/// temporary-folder UUID, `00000000-0000-4000-8000-000000000002`. Nothing was
/// trimmed. The
/// sendMemoryWarning capture is the phone's failure (`NSPOSIXErrorDomain` 2),
/// the orientation-set capture the phone's success answer that reports the
/// pose unchanged (portrait).
final class ApplePhysicalControlsTests: XCTestCase {
    private static let id = ApplePhysicalDeviceTests.coreDeviceIdentifier

    private func url(_ name: String) -> URL { ApplePhysicalDeviceTests.url(name) }
    private func data(_ name: String) throws -> Data { try ApplePhysicalDeviceTests.data(name) }

    private func makeClient(_ fake: FakeTool) throws -> DevicectlPhysicalClient {
        try DevicectlPhysicalClient(
            devicectlURL: fake.executableURL,
            device: try ApplePhysicalDeviceTests.device(),
            commandTimeout: .seconds(30)
        )
    }

    /// The whole argv of one call: the command's words (three or four),
    /// `--device <id> --json-output <temporary file> -q -t 30`, then the tail.
    private func assertArgv(
        _ argv: [String],
        words: [String],
        tail: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let count = words.count
        XCTAssertGreaterThanOrEqual(argv.count, count + 7, "\(argv)", file: file, line: line)
        guard argv.count >= count + 7 else { return }
        XCTAssertEqual(Array(argv.prefix(count)), words, file: file, line: line)
        XCTAssertEqual(Array(argv[count...(count + 2)]), ["--device", Self.id, "--json-output"], file: file, line: line)
        XCTAssertTrue(argv[count + 3].hasSuffix(".json"), file: file, line: line)
        XCTAssertEqual(Array(argv[(count + 4)...(count + 6)]), ["-q", "-t", "30"], file: file, line: line)
        XCTAssertEqual(Array(argv.dropFirst(count + 7)), tail, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: argv[count + 3]), "the temporary file is removed", file: file, line: line)
        ApplePhysicalDeviceTests.assertSafeArguments(argv, file: file, line: line)
    }

    private func decode<Value: Decodable & Sendable>(_ type: Value.Type, _ name: String) throws -> Value {
        try DevicectlJSON.decode(type, from: try data(name)).value
    }

    // MARK: - Appearance

    func testAppearanceSettingsRunOneFlagAndDecodeTheirCaptures() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("--mode dark", jsonOutputFile: url("devicectl-settings-appearance-mode-dark.json")),
            .init("--text-size small", jsonOutputFile: url("devicectl-settings-appearance-text-size-small.json")),
            .init("--reduce-motion on", jsonOutputFile: url("devicectl-settings-appearance-reduce-motion-on.json")),
            .init("--reduce-transparency on", jsonOutputFile: url("devicectl-settings-appearance-reduce-transparency-on.json")),
            .init("--increase-contrast on", jsonOutputFile: url("devicectl-settings-appearance-increase-contrast-on.json")),
            .init("--show-borders on", jsonOutputFile: url("devicectl-settings-appearance-show-borders-on.json")),
            .init("--liquid-glass-opacity 0.70", jsonOutputFile: url("devicectl-settings-appearance-liquid-glass-opacity.json")),
            .init("--color-filter-type grayscale", jsonOutputFile: url("devicectl-settings-appearance-color-filter-type-grayscale.json")),
            .init("--color-filter off", jsonOutputFile: url("devicectl-settings-appearance-color-filter-off.json")),
        ])
        let client = try makeClient(fake)
        let words = ["device", "settings", "appearance"]

        let dark = try await client.setAppearance(.dark(true)).value
        XCTAssertEqual(dark.userInterfaceStyle, "dark")
        let small = try await client.setAppearance(.textSize(.small)).value
        XCTAssertEqual(small.contentSize, .small)
        let motion = try await client.setAppearance(.reduceMotion(true)).value
        XCTAssertEqual(motion.reduceMotion, true)
        let transparency = try await client.setAppearance(.reduceTransparency(true)).value
        XCTAssertEqual(transparency.reduceTransparency, true)
        let contrast = try await client.setAppearance(.increaseContrast(true)).value
        XCTAssertEqual(contrast.increaseContrast, true)
        let borders = try await client.setAppearance(.showBorders(true)).value
        XCTAssertEqual(borders.showBorders, true)
        let glass = try await client.setAppearance(.liquidGlassOpacity(0.7)).value
        XCTAssertEqual(glass.liquidGlassOpacity ?? 0, 0.7, accuracy: 0.0001)
        let gray = try await client.setAppearance(.colorFilterType(.grayscale, intensity: nil)).value
        XCTAssertEqual(gray.colorFilterSelection, .grayscale)
        let off = try await client.setAppearance(.colorFilter(false)).value
        XCTAssertEqual(off.colorFilter, false)

        let invocations = fake.invocations
        XCTAssertEqual(invocations.count, 9)
        assertArgv(invocations[0], words: words, tail: ["--mode", "dark"])
        assertArgv(invocations[1], words: words, tail: ["--text-size", "small"])
        assertArgv(invocations[2], words: words, tail: ["--reduce-motion", "on"])
        assertArgv(invocations[3], words: words, tail: ["--reduce-transparency", "on"])
        assertArgv(invocations[4], words: words, tail: ["--increase-contrast", "on"])
        assertArgv(invocations[5], words: words, tail: ["--show-borders", "on"])
        assertArgv(invocations[6], words: words, tail: ["--liquid-glass-opacity", "0.70"])
        assertArgv(invocations[7], words: words, tail: ["--color-filter-type", "grayscale"])
        assertArgv(invocations[8], words: words, tail: ["--color-filter", "off"])
    }

    /// The reads that confirm a write: the phone's own `info appearance`.
    func testTheAppearanceReadsOfTheCapturesDecode() throws {
        let baseline = try decode(DevicectlAppearance.self, "devicectl-info-appearance-baseline.json")
        XCTAssertEqual(baseline.userInterfaceStyle, "light")
        XCTAssertEqual(baseline.contentSize, .large)
        XCTAssertEqual(baseline.largerAccessibilitySizesEnabled, true)
        XCTAssertEqual(baseline.liquidGlassOpacity, 0.5)
        XCTAssertEqual(baseline.colorFilter, false)
        XCTAssertEqual(baseline.supportedLooksAndFeels, ["Liquid Glass"])
        let dark = try decode(DevicectlAppearance.self, "devicectl-info-appearance-dark.json")
        XCTAssertEqual(dark.userInterfaceStyle, "dark")
        let gray = try decode(DevicectlAppearance.self, "devicectl-info-appearance-grayscale.json")
        XCTAssertEqual(gray.colorFilterSelection, .grayscale)
        XCTAssertNil(gray.colorFilterIntensity, "grayscale has no intensity")
    }

    func testAnAppearanceValueDevicectlWouldRejectIsRefusedBeforeItRuns() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let client = try makeClient(fake)
        func expectRefusal(_ label: String, _ setting: DevicectlAppearanceSetting) async {
            do {
                _ = try await client.setAppearance(setting)
                XCTFail("\(label) must be refused")
            } catch is DevicectlClientError {
            } catch {
                XCTFail("\(label): \(error)")
            }
        }
        await expectRefusal("unknown text size", .textSize(.unknown))
        await expectRefusal("opacity above 1", .liquidGlassOpacity(1.5))
        await expectRefusal("intensity below 0.25", .colorFilterType(.protanopia, intensity: 0.1))
        XCTAssertEqual(fake.calls, [])
    }

    // MARK: - VoiceOver, orientation

    func testVoiceOverSetsAndDecodes() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("--enable", jsonOutputFile: url("devicectl-settings-voiceover-enable.json")),
            .init("--disable", jsonOutputFile: url("devicectl-settings-voiceover-disable.json")),
        ])
        let client = try makeClient(fake)
        let on = try await client.setVoiceOver(true).value
        XCTAssertEqual(on.enabled, true)
        XCTAssertEqual(on.operation, "enable")
        let off = try await client.setVoiceOver(false).value
        XCTAssertEqual(off.enabled, false)
        XCTAssertEqual(off.operation, "disable")
        assertArgv(fake.invocations[0], words: ["device", "settings", "voiceover"], tail: ["--enable"])
        assertArgv(fake.invocations[1], words: ["device", "settings", "voiceover"], tail: ["--disable"])
        XCTAssertEqual(try decode(DevicectlVoiceOver.self, "devicectl-info-voiceover-on.json").operation, "query")
    }

    /// `orientation set` on the iPhone 12 answers success and the pose it
    /// reports stays portrait: the capture behind hiding the Orientation row.
    func testOrientationSetAnswersSuccessAndReportsPortrait() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("orientation set", jsonOutputFile: url("devicectl-orientation-set-landscapeLeft.json")),
            .init("orientation get", jsonOutputFile: url("devicectl-orientation-get.json")),
        ])
        let client = try makeClient(fake)
        let set = try await client.setOrientation(.landscapeLeft).value
        XCTAssertEqual(set.deviceOrientation, "portrait")
        let got = try await client.orientation().value
        XCTAssertEqual(got.deviceOrientation, "portrait")
        XCTAssertEqual(got.deviceIsOrientationLocked, false)
        assertArgv(fake.invocations[0], words: ["device", "orientation", "set"], tail: ["landscapeLeft"])
        assertArgv(fake.invocations[1], words: ["device", "orientation", "get"], tail: [])
    }

    // MARK: - Location

    func testLocationSetsACoordinateAndClearsIt() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("location coordinate", jsonOutputFile: url("devicectl-simulate-location-coordinate.json")),
            .init("location clear", jsonOutputFile: url("devicectl-simulate-location-clear.json")),
        ])
        let client = try makeClient(fake)
        let set = try await client.setLocation(latitude: 41.0082, longitude: 28.9784).value
        XCTAssertEqual(set.latitude, 41.0082)
        XCTAssertEqual(set.longitude, 28.9784)
        let cleared = try await client.clearLocation().value
        XCTAssertTrue(cleared.cleared)
        let words = ["device", "simulate", "location"]
        // Four words: `coordinate` and `clear` belong to the subcommand.
        assertArgv(fake.invocations[0], words: words + ["coordinate"], tail: ["--latitude", "41.008200", "--longitude", "28.978400"])
        assertArgv(fake.invocations[1], words: words + ["clear"], tail: [])
    }

    func testACoordinateOutsideTheGlobeIsRefused() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let client = try makeClient(fake)
        for (latitude, longitude) in [(91.0, 0.0), (-91.0, 0.0), (0.0, 181.0), (0.0, -181.0), (.nan, 0.0), (0.0, .infinity)] {
            do {
                _ = try await client.setLocation(latitude: latitude, longitude: longitude)
                XCTFail("\(latitude), \(longitude) must be refused")
            } catch is DevicectlClientError {
            }
        }
        XCTAssertEqual(fake.calls, [])
    }

    // MARK: - Memory warning

    /// The phone fails the call (`NSPOSIXErrorDomain` 2) even for a running
    /// app: the real error decodes as a plain `DevicectlError`.
    func testTheMemoryWarningFailureDecodes() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("sendMemoryWarning", jsonOutputFile: url("devicectl-process-sendMemoryWarning.json"), exitCode: 1),
        ])
        let client = try makeClient(fake)
        do {
            _ = try await client.sendMemoryWarning(pid: 5076)
            XCTFail("expected the phone's failure")
        } catch let error as DevicectlError {
            XCTAssertEqual(error.frames.first?.domain, "NSPOSIXErrorDomain")
            XCTAssertEqual(error.frames.first?.code, 2)
        }
        assertArgv(fake.invocations[0], words: ["device", "process", "sendMemoryWarning"], tail: ["--pid", "5076"])
        do {
            _ = try await client.sendMemoryWarning(pid: 0)
            XCTFail("a pid of 0 must be refused")
        } catch is DevicectlClientError {
        }
    }

    // MARK: - Pasteboard

    func testThePasteboardCopiesTextThroughAFileAndPastesItBack() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("pasteboard copy", jsonOutputFile: url("devicectl-pasteboard-copy.json")),
            .init(
                "pasteboard paste",
                jsonOutputFile: url("devicectl-pasteboard-paste.json"),
                stdoutFile: url("devicectl-pasteboard-paste.stdout.txt")
            ),
        ])
        let client = try makeClient(fake)
        let copied = try await client.copyToPasteboard("devicehubpro-pasteboard-test").value
        XCTAssertEqual(copied.itemCount, 1)
        XCTAssertEqual(copied.types, ["public.utf8-plain-text", "public.plain-text", "public.text"])
        let pasted = try await client.pasteboardText()
        XCTAssertEqual(pasted.text, "devicehubpro-pasteboard-test")
        XCTAssertEqual(pasted.info.contentSize, 24)
        XCTAssertEqual(pasted.info.contentType, "public.utf8-plain-text")

        let copyArgv = fake.invocations[0]
        // The text never rides the command line: a temporary file does, and
        // it is gone after the call.
        XCTAssertFalse(copyArgv.contains("devicehubpro-pasteboard-test"))
        let fileIndex = try XCTUnwrap(copyArgv.firstIndex(of: "--file"))
        let file = copyArgv[fileIndex + 1]
        XCTAssertTrue(file.hasSuffix(".txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
        assertArgv(copyArgv, words: ["device", "pasteboard", "copy"], tail: ["--file", file])
        assertArgv(fake.invocations[1], words: ["device", "pasteboard", "paste"], tail: [])
    }

    func testAnEmptyOrHugePasteboardTextIsRefused() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let client = try makeClient(fake)
        for text in ["", String(repeating: "a", count: DevicectlPhysicalClient.maximumPasteboardBytes + 1)] {
            do {
                _ = try await client.copyToPasteboard(text)
                XCTFail("\(text.count) characters must be refused")
            } catch is DevicectlClientError {
            }
        }
        XCTAssertEqual(fake.calls, [])
    }

    // MARK: - The gate

    /// Every other word under `settings`, `simulate`, `orientation` and
    /// `pasteboard` stays refused, and every Controls command with a
    /// malformed tail is refused, before devicectl runs.
    func testEveryOtherControlShapeIsRefused() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let client = try makeClient(fake)
        let refused: [[String]] = [
            // Other settings and simulations.
            ["device", "settings", "biometrics"],
            ["device", "settings", "biometrics", "--enable"],
            ["device", "settings", "reset"],
            ["device", "settings", "audio", "--volume", "50"],
            ["device", "simulate", "biometrics", "--success"],
            ["device", "simulate", "location", "scenario", "--name", "x"],
            ["device", "simulate", "location", "route"],
            ["device", "simulate", "location", "list"],
            ["device", "simulate", "location"],
            ["device", "simulate", "motion"],
            ["device", "orientation", "rotate"],
            ["device", "orientation"],
            ["device", "pasteboard", "info"],
            ["device", "pasteboard", "monitor"],
            ["device", "pasteboard", "transfer"],
            ["device", "pasteboard", "sync-with-host"],
            ["device", "process", "sendSignal", "--pid", "1"],
            // Appearance: a malformed tail.
            ["device", "settings", "appearance"],
            ["device", "settings", "appearance", "--mode"],
            ["device", "settings", "appearance", "--mode", "auto"],
            ["device", "settings", "appearance", "--mode", "dark", "--reduce-motion", "on"],
            ["device", "settings", "appearance", "--reduce-motion", "true"],
            ["device", "settings", "appearance", "--look-and-feel", "clear"],
            ["device", "settings", "appearance", "--text-size", "huge"],
            ["device", "settings", "appearance", "--text-size", "unknown"],
            ["device", "settings", "appearance", "--liquid-glass-opacity", "1.5"],
            ["device", "settings", "appearance", "--liquid-glass-opacity", "abc"],
            ["device", "settings", "appearance", "--color-filter-intensity", "0.5"],
            ["device", "settings", "appearance", "--color-filter-type", "sepia"],
            ["device", "settings", "appearance", "--color-filter-type", "grayscale", "--color-filter-intensity", "0.5"],
            ["device", "settings", "appearance", "--color-filter-type", "protanopia", "--color-filter-intensity", "0.1"],
            ["device", "settings", "appearance", "--color-filter-type", "protanopia", "--color-filter-intensity"],
            ["device", "settings", "appearance", "--help"],
            // VoiceOver, orientation, location, memory warning, pasteboard.
            ["device", "settings", "voiceover"],
            ["device", "settings", "voiceover", "--enable", "--disable"],
            ["device", "settings", "voiceover", "on"],
            ["device", "orientation", "get", "--json"],
            ["device", "orientation", "set"],
            ["device", "orientation", "set", "sideways"],
            ["device", "orientation", "set", "p"],
            ["device", "simulate", "location", "coordinate"],
            ["device", "simulate", "location", "coordinate", "--latitude", "91", "--longitude", "0"],
            ["device", "simulate", "location", "coordinate", "--latitude", "1", "--longitude", "181"],
            ["device", "simulate", "location", "coordinate", "--latitude", "abc", "--longitude", "0"],
            ["device", "simulate", "location", "coordinate", "--longitude", "0", "--latitude", "1"],
            ["device", "simulate", "location", "clear", "--now"],
            ["device", "process", "sendMemoryWarning"],
            ["device", "process", "sendMemoryWarning", "--pid", "0"],
            ["device", "process", "sendMemoryWarning", "--pid", "1", "--pid", "2"],
            ["device", "pasteboard", "copy"],
            ["device", "pasteboard", "copy", "--file"],
            ["device", "pasteboard", "copy", "--file", "-x"],
            ["device", "pasteboard", "copy", "--type", "public.png", "--file", "/tmp/a"],
            ["device", "pasteboard", "copy", "--device-pasteboard", "general", "--file", "/tmp/a"],
            ["device", "pasteboard", "paste", "--type", "public.png"],
            ["device", "pasteboard", "paste", "--item", "1"],
        ]
        for command in refused {
            do {
                _ = try await client.run(command, as: DevicectlIgnoredResult.self)
                XCTFail("\(command) must be refused")
            } catch let error as DevicectlClientError {
                XCTAssertEqual(error, .refusedCommand(command.joined(separator: " ")), "\(command)")
            }
        }
        XCTAssertEqual(fake.calls, [], "devicectl never ran")
    }

    /// The refusal words stay on the list, whatever shapes are allowed.
    func testTheRefusalListStillNamesTheControlWords() {
        for word in ["settings", "simulate", "orientation", "pasteboard", "motion", "notification", "appResize"] {
            XCTAssertTrue(DevicectlPhysicalClient.refusedCommands.contains(word), word)
        }
    }

    // MARK: - Capabilities and routing

    private func iPhone12Capabilities() throws -> ApplePhysicalControlsCapabilities {
        ApplePhysicalControlsCapabilities(details: try decode(DevicectlDeviceDetails.self, "devicectl-info-details.json"))
    }

    /// The iPhone 12's capability list turns into exactly the rows its
    /// features allow: eleven controls offered, the rest hidden with a reason.
    func testTheIPhone12OffersTheRowsItsFeaturesAllow() throws {
        let capabilities = try iPhone12Capabilities()
        for feature in ApplePhysicalFeature.allCases where feature != .audioOutput {
            XCTAssertTrue(capabilities.lists(feature), feature.rawValue)
        }
        XCTAssertFalse(capabilities.lists(.audioOutput), "the captured 1001: no audio output selection")

        let offered = AppleControl.allCases.filter {
            AppleControlsRouting.physicalRoute($0, capabilities: capabilities).isOffered
        }
        XCTAssertEqual(offered, [
            .appearance, .liquidGlass, .textSize, .reduceMotion, .showBorders, .reduceTransparency, .voiceOver,
            .colorFilter, .increaseContrast, .location, .clipboard,
        ])
        for control in AppleControl.allCases where !offered.contains(control) {
            let route = AppleControlsRouting.physicalRoute(control, capabilities: capabilities)
            XCTAssertNil(route.mechanism, "\(control)")
            XCTAssertFalse((route.support.unavailableReason ?? "").isEmpty, "\(control) says why")
        }
        // Every offered row goes through devicectl and is live.
        for control in offered {
            let route = AppleControlsRouting.physicalRoute(control, capabilities: capabilities)
            XCTAssertEqual(route.mechanism?.kind, .devicectl, "\(control)")
            XCTAssertEqual(route.support, .live, "\(control)")
        }
    }

    /// A feature the phone does not list hides its rows; nothing else moves.
    func testARowWhoseFeatureIsAbsentIsHidden() throws {
        var identifiers = try iPhone12Capabilities().identifiers
        identifiers.remove(ApplePhysicalFeature.customizeLiquidGlass.rawValue)
        identifiers.remove(ApplePhysicalFeature.pasteboard.rawValue)
        let capabilities = ApplePhysicalControlsCapabilities(identifiers: identifiers)
        let liquid = AppleControlsRouting.physicalRoute(.liquidGlass, capabilities: capabilities)
        XCTAssertFalse(liquid.isOffered)
        XCTAssertTrue(liquid.support.unavailableReason?.contains("Customize Liquid Glass") == true)
        XCTAssertFalse(AppleControlsRouting.physicalRoute(.clipboard, capabilities: capabilities).isOffered)
        XCTAssertTrue(AppleControlsRouting.physicalRoute(.appearance, capabilities: capabilities).isOffered)
        XCTAssertTrue(AppleControlsRouting.physicalRoute(.location, capabilities: capabilities).isOffered)
        let none = ApplePhysicalControlsCapabilities(identifiers: [])
        XCTAssertTrue(AppleControl.allCases.allSatisfy { !AppleControlsRouting.physicalRoute($0, capabilities: none).isOffered })
    }

    /// The simulator-only rows say so, and the measured failures say what was
    /// measured.
    func testTheReasonsForHiddenRows() throws {
        let capabilities = try iPhone12Capabilities()
        func reason(_ control: AppleControl) -> String? {
            AppleControlsRouting.physicalRoute(control, capabilities: capabilities).support.unavailableReason
        }
        for control in [AppleControl.push, .permissions, .openURL, .language, .timeFormat24, .timeZone, .statusBar] {
            XCTAssertEqual(reason(control), AppleControlsRouting.physicalSimulatorOnly, "\(control)")
        }
        XCTAssertEqual(reason(.orientation), AppleControlsRouting.physicalOrientationUnavailable)
        XCTAssertEqual(reason(.memoryWarning), AppleControlsRouting.physicalMemoryWarningUnavailable)
        XCTAssertEqual(reason(.volume), AppleControlsRouting.physicalVolumeUnavailable)
        XCTAssertEqual(reason(.biometrics), AppleControlsRouting.physicalBiometricsUnavailable)
    }

    // MARK: - The backend

    private func backend(_ fake: FakeTool) throws -> ApplePhysicalControlsBackend {
        ApplePhysicalControlsBackend(client: try makeClient(fake), capabilities: try iPhone12Capabilities())
    }

    func testTheBackendReadsAndPollsWhatTheOfferedRowsNeed() throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let backend = try backend(fake)
        XCTAssertEqual(backend.deviceIdentifier, ApplePhysicalDeviceTests.udid)
        XCTAssertEqual(backend.initialReads(), [.devicectlAppearance, .devicectlVoiceOver])
        XCTAssertEqual((0..<4).map { backend.pollRead(forTick: $0) }, [
            .devicectlAppearance, .devicectlVoiceOver, .devicectlAppearance, .devicectlVoiceOver,
        ])
        XCTAssertEqual(backend.pollInterval, .seconds(3))

        // Without VoiceOver and the appearance features there is nothing to read.
        let bare = ApplePhysicalControlsBackend(
            client: try makeClient(fake),
            capabilities: ApplePhysicalControlsCapabilities(identifiers: [ApplePhysicalFeature.pasteboard.rawValue])
        )
        XCTAssertEqual(bare.initialReads(), [])
        XCTAssertNil(bare.pollRead(forTick: 3))
    }

    func testTheBackendAppliesChangesAndReturnsTheAnswerAsAReading() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("--mode dark", jsonOutputFile: url("devicectl-settings-appearance-mode-dark.json")),
            .init("--enable", jsonOutputFile: url("devicectl-settings-voiceover-enable.json")),
            .init("info appearance", jsonOutputFile: url("devicectl-info-appearance-dark.json")),
            .init("location coordinate", jsonOutputFile: url("devicectl-simulate-location-coordinate.json")),
            .init("location clear", jsonOutputFile: url("devicectl-simulate-location-clear.json")),
            .init("pasteboard copy", jsonOutputFile: url("devicectl-pasteboard-copy.json")),
        ])
        let backend = try backend(fake)
        let appearance = try await backend.apply(.appearance(dark: true))
        guard case .appearance(let answer)? = appearance else { return XCTFail("\(String(describing: appearance))") }
        XCTAssertEqual(answer.userInterfaceStyle, "dark")
        let voiceOver = try await backend.apply(.voiceOver(true))
        XCTAssertEqual(voiceOver, .voiceOver(true))
        let location = try await backend.apply(.location(latitude: 41.0082, longitude: 28.9784))
        XCTAssertNil(location)
        let cleared = try await backend.apply(.clearLocation)
        XCTAssertNil(cleared)
        let copy = try await backend.apply(.pasteboard("hello"))
        XCTAssertNil(copy)
        let read = try await backend.read(.devicectlAppearance)
        guard case .appearance(let whole) = read else { return XCTFail("\(read)") }
        XCTAssertEqual(whole.userInterfaceStyle, "dark")
        // The merged state a read leaves.
        var state = AppleControlsState()
        state.apply(read)
        XCTAssertEqual(state.dark, true)
        XCTAssertEqual(state.textSize, .large)
        XCTAssertEqual(state.liquidGlassOpacity, 0.5)
    }

    /// A text size in the accessibility range first turns Larger
    /// Accessibility Sizes on; the standard sizes are one call.
    func testAnAccessibilityTextSizeTakesTwoCalls() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("--larger-accessibility-sizes on", jsonOutputFile: url("devicectl-settings-appearance-text-size-small.json")),
            .init("--text-size", jsonOutputFile: url("devicectl-settings-appearance-text-size-small.json")),
        ])
        let backend = try backend(fake)
        try await backend.apply(.textSize(.small))
        XCTAssertEqual(fake.invocations.count, 1)
        try await backend.apply(.textSize(.accessibilityLarge))
        XCTAssertEqual(fake.invocations.count, 3)
        XCTAssertTrue(fake.calls[1].contains("--larger-accessibility-sizes on"), fake.calls[1])
        XCTAssertTrue(fake.calls[2].contains("--text-size accessibility-large"), fake.calls[2])
    }

    /// A row that is hidden is never run, and a scenario or route (which a
    /// phone has no shape for) is refused as well.
    func testTheBackendRefusesWhatIsNotOffered() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let backend = try backend(fake)
        let refused: [AppleControlChange] = [
            .orientation(.landscapeLeft), .volume(50), .biometricsEnrolled(true), .biometricMatch(success: true),
            .push(bundleIdentifier: "a.b", payload: try SimulatorPushPayload(SimulatorPushPayload.template)),
            .privacy(.grant, .photos, bundleIdentifier: "a.b"), .openURL(URL(string: "https://example.com")!),
            .timeFormat(.twentyFourHour), .statusBar(nil), .respring, .locationScenario("City Run"),
            .locationRoute([SimulatorWaypoint(latitude: 1, longitude: 2)], speed: 5),
        ]
        for change in refused {
            do {
                _ = try await backend.apply(change)
                XCTFail("\(change) must not run")
            } catch is AppleControlsError {
            }
        }
        XCTAssertEqual(fake.calls, [])
    }

    /// CoreDevice 1001 from a call takes that feature's rows out.
    func testAnUnsupportedCapabilityHidesItsRowsForTheRestOfTheRun() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("pasteboard copy", jsonOutputFile: url("devicectl-info-audio.json"), exitCode: 1),
        ])
        let backend = try backend(fake)
        XCTAssertTrue(backend.route(.clipboard).isOffered)
        do {
            // The audio capture is CoreDevice's 1001: a stand-in answer for any call.
            _ = try await backend.apply(.pasteboard("x"))
            XCTFail("expected 1001")
        } catch DevicectlPhysicalError.unsupportedCapability {
        }
        // The stand-in names the audio feature, not the pasteboard's: only it is recorded.
        XCTAssertEqual(backend.unsupportedFeatures, [ApplePhysicalFeature.audioOutput.rawValue])
        XCTAssertTrue(backend.route(.clipboard).isOffered)
        backend.recordUnsupported(ApplePhysicalFeature.pasteboard.rawValue)
        XCTAssertFalse(backend.route(.clipboard).isOffered)
        XCTAssertTrue(backend.route(.appearance).isOffered)
    }

    func testThePasteboardTextComesFromDevicectlsStandardOutput() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init(
                "pasteboard paste",
                jsonOutputFile: url("devicectl-pasteboard-paste.json"),
                stdoutFile: url("devicectl-pasteboard-paste.stdout.txt")
            ),
        ])
        let text = try await backend(fake).pasteboardText()
        XCTAssertEqual(text, "devicehubpro-pasteboard-test")
    }
}
