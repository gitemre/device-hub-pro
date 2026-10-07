import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The Color Filter and Color inversion rows over a stub adb answering with
/// the API 37 emulator's captures (`DeviceHubProKitTests/Fixtures/api37-emulator`,
/// byte-exact: `controls/getprop-ro.build.version.sdk.txt` and the
/// `color-filters` readings probes). A state file names the capture the probe
/// answers with; the write arms move it the way the device moved.
@MainActor
final class ColorFilterControllerTests: XCTestCase {
    private static let serial = "emulator-5580"

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DeviceHubProKitTests/Fixtures/api37-emulator")

    private static let protanopiaWrite =
        "-s \(serial) shell settings put secure accessibility_display_daltonizer 11 && settings put secure accessibility_display_daltonizer_enabled 1"
    private static let noneWrite =
        "-s \(serial) shell settings put secure accessibility_display_daltonizer_enabled 0"
    private static let inversionOnWrite =
        "-s \(serial) shell settings put secure accessibility_display_inversion_enabled 1"
    private static let tritanopiaWrite =
        "-s \(serial) shell settings put secure accessibility_display_daltonizer 13 && settings put secure accessibility_display_daltonizer_enabled 1"

    private func quoted(_ url: URL) -> String { AdbClient.shellQuoted(url.path) }

    /// A fresh directory for the stub's state files.
    private func stateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cf-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// A stub whose probe answers with `readings-probe-<state>.txt`, starting
    /// at `start`. `extra` arms come first; `writes` false leaves the write
    /// arms out (unmatched calls exit 1). While `slow` exists, the probe picks
    /// its answer, then waits a second before printing it; while `slow-put`
    /// exists, the Protanopia put moves the state, then waits half a second
    /// before it exits.
    private func stub(start: String, extra: String = "", writes: Bool = true) throws -> (StubAdb, URL) {
        let state = try stateDirectory()
        try Data("\(start)\n".utf8).write(to: state.appendingPathComponent("state"))
        let stateFile = quoted(state.appendingPathComponent("state"))
        let slow = quoted(state.appendingPathComponent("slow"))
        let slowPut = quoted(state.appendingPathComponent("slow-put"))
        let colorFilters = quoted(Self.fixtures.appendingPathComponent("color-filters"))
        let writeArms = writes ? """
          "\(Self.protanopiaWrite)")
            echo protanopia > \(stateFile)
            if [ -f \(slowPut) ]; then sleep 0.5; fi ;;
          "\(Self.tritanopiaWrite)")
            echo tritanopia > \(stateFile) ;;
          "\(Self.noneWrite)")
            echo none-mode-kept > \(stateFile) ;;
          "\(Self.inversionOnWrite)")
            echo inversion > \(stateFile) ;;
        """ : ""
        let adb = try makeStubAdb(arms: """
        \(extra)
          "-s \(Self.serial) shell getprop ro.build.version.sdk")
            cat \(quoted(Self.fixtures.appendingPathComponent("controls/getprop-ro.build.version.sdk.txt"))) ;;
          "-s \(Self.serial) shell echo @@devicehubpro-cf:enabled"*)
            answer=\(colorFilters)/"readings-probe-$(cat \(stateFile)).txt"
            [ -f \(slow) ] && sleep 1
            cat "$answer" ;;
        \(writeArms)
        """)
        return (adb, state)
    }

    private func makeController(
        adb: AdbClient?,
        serial: String? = ColorFilterControllerTests.serial,
        port: Int? = 5581
    ) -> (ColorFilterController, ActiveDeviceContext, StatusCenter) {
        let context = ActiveDeviceContext()
        context.serial = serial
        context.port = port
        let status = StatusCenter()
        return (ColorFilterController(adbClient: adb, context: context, status: status), context, status)
    }

    // MARK: - Poll

    func testTheFirstPollProbesOnceAndShowsBothRows() async throws {
        let (adb, _) = try stub(start: "off")
        let (controller, _, _) = makeController(adb: adb.client)
        XCTAssertFalse(controller.showsColorFilterRow, "nothing shows before the device answers")

        await controller.refresh()
        await controller.refresh()
        XCTAssertEqual(adb.calls(containing: "getprop ro.build.version.sdk").count, 1, "the API level is read once per device")
        XCTAssertEqual(adb.calls(containing: "@@devicehubpro-cf:enabled").count, 2)
        XCTAssertTrue(adb.calls(containing: "@@devicehubpro-cf:enabled").allSatisfy { $0.contains("dumpsys SurfaceFlinger --comp-displays") })
        XCTAssertEqual(controller.support, ColorFilterSupport(apiLevel: 37))
        XCTAssertTrue(controller.showsColorFilterRow)
        XCTAssertEqual(controller.readings?.setting, .filter(.none))
        XCTAssertEqual(controller.readings?.inversion, false)
        XCTAssertEqual(controller.check, .applied(level: nil))
        XCTAssertTrue(controller.isEmulator)
        XCTAssertTrue(adb.calls(containing: "settings put").isEmpty, "a poll writes nothing")
    }

    func testThreeFailedReadsHideTheRowsAndAnAnswerBringsThemBack() async throws {
        let state = try stateDirectory()
        let gate = state.appendingPathComponent("gate")
        let adb = try makeStubAdb(arms: """
          "-s \(Self.serial) shell getprop ro.build.version.sdk")
            cat \(quoted(Self.fixtures.appendingPathComponent("controls/getprop-ro.build.version.sdk.txt"))) ;;
          "-s \(Self.serial) shell echo @@devicehubpro-cf:enabled"*)
            [ -f \(quoted(gate)) ] || exit 1
            cat \(quoted(Self.fixtures.appendingPathComponent("color-filters/readings-probe-grayscale.txt"))) ;;
        """)
        let (controller, _, _) = makeController(adb: adb.client)
        await controller.refresh()
        XCTAssertTrue(controller.showsColorFilterRow, "two failures keep the rows")
        for _ in 0..<2 { await controller.refresh() }
        XCTAssertNil(controller.readings)
        XCTAssertNil(controller.check)
        XCTAssertFalse(controller.showsColorFilterRow)

        try Data().write(to: gate)
        await controller.refresh()
        XCTAssertTrue(controller.showsColorFilterRow)
        XCTAssertEqual(controller.readings?.setting, .filter(.grayscale))
    }

    func testThePollDropsReadsThatOverlappedAWrite() async throws {
        let (adb, state) = try stub(start: "off")
        let (controller, _, status) = makeController(adb: adb.client)
        await controller.refresh()
        XCTAssertEqual(controller.readings?.setting, .filter(.none))

        try Data().write(to: state.appendingPathComponent("slow"))
        let poll = Task { await controller.refresh() }
        await waitUntil { adb.calls(containing: "@@devicehubpro-cf:enabled").count >= 2 }
        await controller.setColorFilter(.protanopia)
        await poll.value
        XCTAssertNil(status.errorMessage)
        XCTAssertEqual(controller.readings?.setting, .filter(.protanopia), "the poll's read of Off overlapped the write")
        XCTAssertEqual(controller.check, .applied(level: 0.7))
        XCTAssertTrue(controller.writeFence.isIdle)
    }

    /// SOURCE-DERIVED: no API 23 image was available. The answer is the API
    /// 37 capture `getprop-ro.build.version.sdk.txt` with its value replaced:
    /// getprop prints the property and a newline on every release.
    func testBelowTheMinimumAPIThePollReadsNothing() async throws {
        let state = try stateDirectory()
        let captured = try String(
            contentsOf: Self.fixtures.appendingPathComponent("controls/getprop-ro.build.version.sdk.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(captured, "37\n")
        let api23 = state.appendingPathComponent("getprop-23.txt")
        try Data(captured.replacingOccurrences(of: "37", with: "23").utf8).write(to: api23)
        let adb = try makeStubAdb(arms: """
          "-s \(Self.serial) shell getprop ro.build.version.sdk")
            cat \(quoted(api23)) ;;
          "-s \(Self.serial) shell echo @@devicehubpro-cf:enabled"*)
            cat \(quoted(Self.fixtures.appendingPathComponent("color-filters/readings-probe-off.txt"))) ;;
        """)
        let (controller, _, _) = makeController(adb: adb.client)
        await controller.refresh()
        await controller.refresh()
        XCTAssertEqual(controller.support, ColorFilterSupport(apiLevel: 23))
        XCTAssertEqual(adb.calls(containing: "getprop ro.build.version.sdk").count, 1)
        XCTAssertTrue(adb.calls(containing: "@@devicehubpro-cf").isEmpty, "the rows are hidden: nothing to read")
        XCTAssertNil(controller.readings)
        XCTAssertFalse(controller.showsColorFilterRow)
    }

    func testAPollForThePreviousDeviceAppliesNothing() async throws {
        let (adb, state) = try stub(start: "off")
        let (controller, context, _) = makeController(adb: adb.client)
        await controller.refresh()
        controller.detach()

        try Data().write(to: state.appendingPathComponent("slow"))
        let poll = Task { await controller.refresh() }
        await waitUntil { adb.calls(containing: "getprop ro.build.version.sdk").count >= 2 }
        await waitUntil { adb.calls(containing: "@@devicehubpro-cf:enabled").count >= 2 }
        context.serial = "emulator-5582"
        context.controlsGeneration += 1
        await poll.value
        XCTAssertNil(controller.readings, "the answer belongs to the device the panel left")
    }

    // MARK: - Writes

    func testChoosingAFilterWritesTheModeFirstAndFlashes() async throws {
        let (adb, _) = try stub(start: "off")
        let (controller, _, status) = makeController(adb: adb.client)
        await controller.refresh()

        await controller.setColorFilter(.protanopia)
        XCTAssertNil(status.errorMessage)
        XCTAssertEqual(status.statusMessage, "Color filter set to Red/Green (Protanopia)")
        XCTAssertEqual(adb.calls.filter { $0 == Self.protanopiaWrite }.count, 1, "the mode, then the switch, in one shell line")
        XCTAssertEqual(controller.readings?.setting, .filter(.protanopia))
        XCTAssertEqual(controller.check, .applied(level: 0.7))
        XCTAssertTrue(controller.writeFence.isIdle)
        XCTAssertFalse(controller.isWriting)
    }

    func testNoneTurnsOnlyTheSwitchOff() async throws {
        let (adb, _) = try stub(start: "protanopia")
        let (controller, _, status) = makeController(adb: adb.client)
        await controller.refresh()
        XCTAssertEqual(controller.readings?.setting, .filter(.protanopia))

        await controller.setColorFilter(.none)
        XCTAssertNil(status.errorMessage)
        XCTAssertEqual(status.statusMessage, "Color filter turned off")
        XCTAssertEqual(adb.calls(containing: "settings put").count, 1)
        XCTAssertEqual(adb.calls(containing: "settings put"), [Self.noneWrite])
        XCTAssertEqual(controller.readings?.setting, .filter(.none))
        XCTAssertEqual(controller.readings?.modeRaw, "11", "the mode stays")
        XCTAssertEqual(controller.check, .applied(level: nil))
    }

    func testAFailedWriteRestoresTheRowAndShowsTheError() async throws {
        let (adb, _) = try stub(start: "off", extra: """
          "\(Self.protanopiaWrite)")
            cat \(quoted(Self.fixtures.appendingPathComponent("color-filters/settings-put-bogusns.stderr.txt"))) >&2
            exit 255 ;;
        """)
        let (controller, _, status) = makeController(adb: adb.client)
        await controller.refresh()

        await controller.setColorFilter(.protanopia)
        let error = try XCTUnwrap(status.errorMessage)
        XCTAssertTrue(error.contains("failed (255)"), error)
        XCTAssertEqual(controller.readings?.setting, .filter(.none), "rolled back")
        XCTAssertEqual(controller.check, .applied(level: nil), "rolled back")
        XCTAssertTrue(adb.calls(containing: "@@devicehubpro-cf:enabled").count == 1, "no read-back after a failed put")
        XCTAssertTrue(controller.writeFence.isIdle)
    }

    func testAWriteTheDeviceDoesNotKeepIsAnError() async throws {
        let (adb, _) = try stub(start: "off", extra: """
          "\(Self.protanopiaWrite)")
            exit 0 ;;
        """)
        let (controller, _, status) = makeController(adb: adb.client)
        await controller.refresh()

        await controller.setColorFilter(.protanopia)
        XCTAssertEqual(
            status.errorMessage,
            "The device did not keep the color filter: secure accessibility_display_daltonizer_enabled reads null."
        )
        XCTAssertEqual(controller.readings?.setting, .filter(.none), "rolled back")
        XCTAssertEqual(controller.check, .applied(level: nil))
        XCTAssertEqual(adb.calls(containing: "@@devicehubpro-cf:enabled").count, 7, "one poll and six read-back attempts")
    }

    /// A second choice while the first write still reads back (the rows
    /// disable during a write, but a double click can land first): the
    /// first write's read-back sees the second's keys, and must neither roll
    /// the rows back nor report that the device did not keep it.
    func testASecondChoiceOvertakesTheFirstWrite() async throws {
        let (adb, state) = try stub(start: "off")
        let (controller, _, status) = makeController(adb: adb.client)
        await controller.refresh()
        XCTAssertFalse(controller.isWriting)

        try Data().write(to: state.appendingPathComponent("slow-put"))
        let stateFile = state.appendingPathComponent("state")
        let first = Task { await controller.setColorFilter(.protanopia) }
        await waitUntil { (try? String(contentsOf: stateFile, encoding: .utf8)) == "protanopia\n" }
        XCTAssertTrue(controller.isWriting, "both rows disable")
        let second = Task { await controller.setColorFilter(.tritanopia) }
        await second.value
        XCTAssertEqual(controller.readings?.setting, .filter(.tritanopia))
        XCTAssertTrue(controller.isWriting, "the first write still runs")
        await first.value

        XCTAssertEqual(try String(contentsOf: stateFile, encoding: .utf8), "tritanopia\n", "the device holds the last choice")
        XCTAssertEqual(controller.readings?.setting, .filter(.tritanopia), "the row shows what the device holds")
        XCTAssertEqual(controller.check, .applied(level: 0.7))
        XCTAssertNil(status.errorMessage, "the overtaken write reports nothing")
        XCTAssertEqual(status.statusMessage, "Color filter set to Blue/Yellow (Tritanopia)")
        XCTAssertFalse(controller.isWriting)
        XCTAssertTrue(controller.writeFence.isIdle)
    }

    func testAWriteThatOutlivesTheDeviceLeavesTheRowsAlone() async throws {
        let (adb, state) = try stub(start: "off")
        let (controller, context, status) = makeController(adb: adb.client)
        await controller.refresh()

        try Data().write(to: state.appendingPathComponent("slow"))
        let write = Task { await controller.setColorFilter(.protanopia) }
        await waitUntil { adb.calls.contains(Self.protanopiaWrite) }
        context.serial = "emulator-5582"
        context.controlsGeneration += 1
        controller.detach()
        await write.value
        XCTAssertNil(controller.readings, "the next device's rows are not the old device's answer")
        XCTAssertNil(controller.check)
        XCTAssertEqual(status.statusMessage, "Color filter set to Red/Green (Protanopia)", "the write itself is still reported")
        XCTAssertTrue(controller.writeFence.isIdle)
    }

    func testDetachForgetsTheDevice() async throws {
        let (adb, _) = try stub(start: "grayscale")
        let (controller, _, _) = makeController(adb: adb.client)
        await controller.refresh()
        XCTAssertEqual(controller.readings?.setting, .filter(.grayscale))

        controller.detach()
        XCTAssertNil(controller.support)
        XCTAssertNil(controller.supportSerial)
        XCTAssertNil(controller.readings)
        XCTAssertNil(controller.check)
        XCTAssertFalse(controller.showsColorFilterRow)
        XCTAssertTrue(adb.calls(containing: "settings").allSatisfy { !$0.contains("settings put") && !$0.contains("settings delete") }, "nothing is restored on the device")
    }

    func testAPhoneIsNotAnEmulator() {
        let (controller, _, _) = makeController(adb: nil, serial: "R5CT000000A", port: nil)
        XCTAssertFalse(controller.isEmulator)
    }

    /// An emulator mirrored through scrcpy (`DHP_FORCE_PHYSICAL`: no
    /// gRPC port) still draws the filters wrongly, and the Status bar group
    /// calls it an emulator too: the captions do not switch to the phone's.
    func testAnEmulatorMirroredWithoutItsPortIsStillAnEmulator() {
        let (controller, context, _) = makeController(adb: nil, port: nil)
        XCTAssertTrue(controller.isEmulator)

        let statusBar = StatusBarDemoController(adbClient: nil, context: context, status: StatusCenter())
        XCTAssertEqual(controller.isEmulator, !statusBar.isPhysical, "one answer across the groups")
    }
}
