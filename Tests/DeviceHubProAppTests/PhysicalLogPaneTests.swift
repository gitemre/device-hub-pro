import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// The physical iPhone's log pane: the pane's
/// state model and wording, and the controller's open, launch, stop and
/// teardown against a fake devicectl (never a real device).
@MainActor
final class PhysicalLogPaneTests: XCTestCase {
    private static let udid = "00000000-0000000000000000"
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DeviceHubProKitTests/Fixtures/ios27-device", isDirectory: true)

    // MARK: - State model

    func testTheActionIsLaunchUntilStreamingThenStop() {
        XCTAssertEqual(PhysicalLogPane.actionTitle(for: .idle), "Launch & Stream")
        XCTAssertEqual(PhysicalLogPane.actionTitle(for: .ended(reason: "x")), "Launch & Stream")
        XCTAssertEqual(PhysicalLogPane.actionTitle(for: .streaming(bundleID: "a.b")), "Stop")
    }

    func testTheActionNeedsAnAppAndAUsablePhoneExceptStopWhichAlwaysWorks() {
        XCTAssertFalse(PhysicalLogPane.canAct(phase: .idle, selectedBundle: nil))
        XCTAssertFalse(PhysicalLogPane.canAct(phase: .idle, selectedBundle: ""))
        XCTAssertTrue(PhysicalLogPane.canAct(phase: .idle, selectedBundle: "a.b"))
        XCTAssertTrue(PhysicalLogPane.canAct(phase: .ended(reason: "x"), selectedBundle: "a.b"), "launch again")
        XCTAssertFalse(PhysicalLogPane.canAct(phase: .loadingApps, selectedBundle: "a.b"))
        XCTAssertFalse(PhysicalLogPane.canAct(phase: .unavailable, selectedBundle: "a.b"))
        XCTAssertTrue(PhysicalLogPane.canAct(phase: .streaming(bundleID: "a.b"), selectedBundle: nil))
    }

    func testTheStatusNamesTheStreamedApp() {
        XCTAssertEqual(PhysicalLogPane.statusText(phase: .streaming(bundleID: "a.b"), appTitle: "Host"), "Streaming Host")
        XCTAssertEqual(PhysicalLogPane.statusText(phase: .streaming(bundleID: "a.b"), appTitle: nil), "Streaming a.b")
        XCTAssertEqual(PhysicalLogPane.statusText(phase: .idle, appTitle: nil), "Choose an app to launch")
    }

    func testTheFootnoteSaysOnlyTheAppsLogsShow() {
        XCTAssertTrue(PhysicalLogPane.footnote.contains("Only the launched app"))
        XCTAssertTrue(PhysicalLogPane.footnote.contains("system log"))
        XCTAssertTrue(PhysicalLogPane.stopHelp.contains("ends the app session"))
    }

    func testAPhysicalIPhoneIsALogSourceThatStreams() {
        XCTAssertTrue(LogSource.physicalApple(udid: "x").streams)
        XCTAssertFalse(LogSource.none.streams)
    }

    func testThePlaceholderBeforeALaunchOffersTheLaunchNotARetry() {
        XCTAssertEqual(LogcatPlaceholder.physicalIdle.title, "Launch an app to see its logs")
        XCTAssertFalse(LogcatPlaceholder.physicalIdle.offersRetry)
    }

    // MARK: - Controller

    private func makeScript(pidFile: URL) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakePhysicalLog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let apps = Self.fixtures.appendingPathComponent("devicectl-info-apps-after-install.json")
        let script = directory.appendingPathComponent("devicectl")
        let body = """
        #!/bin/sh
        JSON_OUT=""; PREV=""
        for ARG in "$@"; do
          if [ "$PREV" = "--json-output" ]; then JSON_OUT="$ARG"; fi
          PREV="$ARG"
        done
        case "$*" in
        *"--console"*)
          echo $$ > '\(pidFile.path)'
          echo '2026-10-01 23:53:20.030000+0300 Demo[0000:000000] [cat] first line'
          exec sleep 120 ;;
        *"info apps"*) cp '\(apps.path)' "$JSON_OUT" ;;
        esac
        """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (directory, script)
    }

    private func makeClient(script: URL) throws -> DevicectlPhysicalClient {
        let optIn = try XCTUnwrap(PhysicalDeviceOptIn(allowedHardwareUDIDs: [Self.udid]))
        let devices = try ApplePhysicalDeviceLister.devices(
            fromListJSON: Data(contentsOf: Self.fixtures.appendingPathComponent("devicectl-list-devices.json")),
            optIn: optIn
        )
        return try DevicectlPhysicalClient(
            devicectlURL: script, device: try XCTUnwrap(devices.first), commandTimeout: .seconds(30)
        )
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testAPhoneWithoutAClientShowsUnavailableAndStreamsNothing() async {
        let controller = LogcatController(adbClient: nil, status: StatusCenter(), picker: TestPicker())
        await controller.openPhysicalLog(udid: Self.udid)
        XCTAssertEqual(controller.physicalLogPhase, .unavailable)
        XCTAssertEqual(controller.logSourceID, Self.udid)
        XCTAssertFalse(controller.isPhysicalStreaming)
        await controller.launchPhysicalApp(bundleID: "com.devicehubpro.verifier")
        XCTAssertEqual(controller.physicalLogPhase, .unavailable)
        XCTAssertFalse(controller.isPhysicalStreaming)
    }

    func testOpeningListsTheAppsButLaunchesNothingUntilAsked() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("pid-\(UUID().uuidString)")
        let (directory, script) = try makeScript(pidFile: pidFile)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = try makeClient(script: script)
        let controller = LogcatController(adbClient: nil, status: StatusCenter(), picker: TestPicker())
        controller.physicalClientSource = { _ in client }

        await controller.openPhysicalLog(udid: Self.udid)
        XCTAssertEqual(controller.physicalLogPhase, .idle)
        XCTAssertEqual(controller.physicalLogApps, [PhysicalLogApp(bundleID: "com.devicehubpro.verifier", title: "AQA Verifier")])
        XCTAssertFalse(controller.isPhysicalStreaming)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path), "no console launch yet")
    }

    func testAFailedAppListShowsUnavailableAndRecoversOnTheNextRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakePhysicalLogFail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let apps = Self.fixtures.appendingPathComponent("devicectl-info-apps-after-install.json")
        let ready = directory.appendingPathComponent("ready")
        let script = directory.appendingPathComponent("devicectl")
        let body = """
        #!/bin/sh
        JSON_OUT=""; PREV=""
        for ARG in "$@"; do
          if [ "$PREV" = "--json-output" ]; then JSON_OUT="$ARG"; fi
          PREV="$ARG"
        done
        case "$*" in
        *"info apps"*)
          if [ -f '\(ready.path)' ]; then cp '\(apps.path)' "$JSON_OUT"; else echo "boom" >&2; exit 1; fi ;;
        esac
        """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let client = try makeClient(script: script)
        let controller = LogcatController(adbClient: nil, status: StatusCenter(), picker: TestPicker())
        controller.packageRefreshInterval = .milliseconds(100)
        controller.physicalClientSource = { _ in client }

        await controller.openPhysicalLog(udid: Self.udid)
        XCTAssertEqual(controller.physicalLogPhase, .unavailable)
        XCTAssertTrue(controller.physicalLogApps.isEmpty)

        FileManager.default.createFile(atPath: ready.path, contents: Data())
        try await waitUntil { controller.physicalLogPhase == .idle && !controller.physicalLogApps.isEmpty }
        XCTAssertEqual(controller.physicalLogApps.first?.bundleID, "com.devicehubpro.verifier")
        controller.closePhysicalLog()
    }

    func testLaunchStreamsThenStopEndsTheSessionAndLeavesNoDevicectl() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("pid-\(UUID().uuidString)")
        let (directory, script) = try makeScript(pidFile: pidFile)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: pidFile)
        }
        let client = try makeClient(script: script)
        let controller = LogcatController(adbClient: nil, status: StatusCenter(), picker: TestPicker())
        controller.physicalClientSource = { _ in client }
        await controller.openPhysicalLog(udid: Self.udid)

        await controller.launchPhysicalApp(bundleID: "com.devicehubpro.verifier")
        XCTAssertEqual(controller.physicalLogPhase, .streaming(bundleID: "com.devicehubpro.verifier"))
        try await waitUntil { controller.logcatEntries.count == 1 }
        XCTAssertEqual(controller.logcatEntries.first?.message, "first line")
        XCTAssertEqual(controller.logcatEntries.first?.subsystem, "cat")
        XCTAssertTrue(controller.logcatStatusText.contains("Streaming"), controller.logcatStatusText)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), 0)

        controller.stopPhysicalStream()
        XCTAssertEqual(controller.physicalLogPhase, .idle)
        XCTAssertFalse(controller.isPhysicalStreaming)
        XCTAssertEqual(controller.logcatEntries.count, 1, "the lines stay on screen after Stop")
        try await waitUntil { kill(pid, 0) == -1 }
        XCTAssertEqual(errno, ESRCH, "devicectl is gone")
    }

    func testTearingTheLogDownEndsTheSessionToo() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("pid-\(UUID().uuidString)")
        let (directory, script) = try makeScript(pidFile: pidFile)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: pidFile)
        }
        let client = try makeClient(script: script)
        let controller = LogcatController(adbClient: nil, status: StatusCenter(), picker: TestPicker())
        controller.physicalClientSource = { _ in client }
        await controller.openPhysicalLog(udid: Self.udid)
        await controller.launchPhysicalApp(bundleID: "com.devicehubpro.verifier")
        try await waitUntil { FileManager.default.fileExists(atPath: pidFile.path) && controller.logcatEntries.count == 1 }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))

        // What the quit, a selection change and leaving Log focus call.
        controller.closePhysicalLog()
        XCTAssertNil(controller.physicalLogUDID)
        XCTAssertFalse(controller.isPhysicalStreaming)
        XCTAssertEqual(controller.physicalLogPhase, .idle)
        try await waitUntil { kill(pid, 0) == -1 }
        XCTAssertEqual(errno, ESRCH, "no orphaned devicectl")
    }

    func testASessionThatEndsByItselfShowsItsReasonAndKeepsTheLines() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakePhysicalLog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("devicectl")
        let body = """
        #!/bin/sh
        echo '2026-10-01 23:53:20.030000+0300 Demo[0000:000000] [cat] last words'
        echo 'App terminated due to signal 11.'
        exit 0
        """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let client = try makeClient(script: script)
        let controller = LogcatController(adbClient: nil, status: StatusCenter(), picker: TestPicker())
        controller.physicalClientSource = { _ in client }
        controller.physicalLogUDID = Self.udid

        await controller.launchPhysicalApp(bundleID: "com.devicehubpro.verifier")
        try await waitUntil {
            if case .ended = controller.physicalLogPhase { return true } else { return false }
        }
        XCTAssertEqual(controller.logcatEntries.map(\.message), ["last words"])
        let reason = try XCTUnwrap(controller.logcatStopReason)
        XCTAssertTrue(reason.contains("signal 11"), reason)
        XCTAssertFalse(controller.isPhysicalStreaming)
    }
}
