import Darwin
import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// `LogcatController` on its own, with a stub adb, a test picker and no
/// `AppModel`: which start owns the stream, what a stop clears, the status
/// line and the export.
@MainActor
final class LogcatControllerTests: XCTestCase {
    private let slowSerial = "emulator-5554"
    private let fastSerial = "emulator-5556"

    func testASupersededOpenNeverInstallsItsStream() async throws {
        let stub = try makeLogcatStubAdb()
        let controller = LogcatController(adbClient: stub.client, status: StatusCenter(), picker: TestPicker())
        addTeardownBlock { @MainActor in controller.stopLogcat() }

        let first = Task { await controller.openLogcat(serial: self.slowSerial) }
        await waitUntil("the first start never listed its packages") {
            !stub.calls(containing: "-s \(self.slowSerial) shell pm list packages").isEmpty
        }
        // A newer start (the Retry, another device) lands while the first
        // one's package list is still in flight.
        await controller.openLogcat(serial: fastSerial)
        await first.value

        XCTAssertEqual(controller.logcatSerial, fastSerial)
        XCTAssertEqual(controller.logcatPackages, ["com.example.fast"])
        await waitUntil("the newer start never launched its stream") {
            !stub.calls(containing: "-s \(self.fastSerial) logcat").isEmpty
        }
        XCTAssertEqual(
            stub.calls(containing: "-s \(slowSerial) logcat"),
            [],
            "the superseded start must not launch a stream"
        )
    }

    func testAStopDuringThePackageLoadStartsNothing() async throws {
        let stub = try makeLogcatStubAdb()
        let controller = LogcatController(adbClient: stub.client, status: StatusCenter(), picker: TestPicker())
        addTeardownBlock { @MainActor in controller.stopLogcat() }

        let open = Task { await controller.openLogcat(serial: self.slowSerial) }
        await waitUntil("the start never listed its packages") {
            !stub.calls(containing: "pm list packages").isEmpty
        }
        controller.stopLogcat()
        await open.value

        XCTAssertNil(controller.logcatSerial)
        XCTAssertTrue(controller.logcatWasStopped)
        XCTAssertEqual(controller.logcatPackages, [], "the stopped start's packages are dropped")
        XCTAssertEqual(stub.calls(containing: " logcat "), [])
    }

    /// An app installed after the log opened (Flutter's `flutter run`, an
    /// APK dropped on the stage) reaches the App picker without reopening
    /// the log; the list used to be read only at open.
    func testAnAppInstalledAfterTheLogOpenedReachesThePicker() async throws {
        let stub = try makeStubAdb(arms: """
          *"pm list packages"*)
            cat "$(dirname "$0")/packages.txt" 2>/dev/null ;;
          *" logcat "*)
            exec sleep 30 ;;
        """)
        let controller = LogcatController(adbClient: stub.client, status: StatusCenter(), picker: TestPicker())
        controller.packageRefreshInterval = .milliseconds(100)
        addTeardownBlock { @MainActor in controller.stopLogcat() }

        await controller.openLogcat(serial: fastSerial)
        XCTAssertEqual(controller.logcatPackages, [])

        try "package:com.example.installed\n".write(
            to: stub.directory.appendingPathComponent("packages.txt"), atomically: true, encoding: .utf8
        )
        await waitUntil("the picker never listed the new app") {
            controller.logcatPackages == ["com.example.installed"]
        }
    }

    /// Opening from a view's task that is cancelled mid-load still lists the
    /// packages (the read no longer inherits the caller's cancellation).
    func testACancelledCallerStillGetsThePackages() async throws {
        let stub = try makeLogcatStubAdb()
        let controller = LogcatController(adbClient: stub.client, status: StatusCenter(), picker: TestPicker())
        addTeardownBlock { @MainActor in controller.stopLogcat() }

        let open = Task { await controller.openLogcat(serial: self.slowSerial) }
        await waitUntil("the start never listed its packages") {
            !stub.calls(containing: "pm list packages").isEmpty
        }
        open.cancel()
        await open.value

        XCTAssertEqual(controller.logcatPackages, ["com.example.slow"])
    }

    func testAFollowedAppThatIsGoneStaysInThePicker() {
        XCTAssertEqual(LogcatController.pickerPackages(["b"], following: "a"), ["a", "b"])
        XCTAssertEqual(LogcatController.pickerPackages(["a", "b"], following: "a"), ["a", "b"])
        XCTAssertEqual(LogcatController.pickerPackages(["b"], following: nil), ["b"])
    }

    func testStopEndsTheStreamAndClearsWhatItShowed() async throws {
        let stub = try makeLogcatStubAdb()
        let controller = LogcatController(adbClient: stub.client, status: StatusCenter(), picker: TestPicker())
        addTeardownBlock { @MainActor in controller.stopLogcat() }

        await controller.openLogcat(serial: fastSerial)
        XCTAssertFalse(controller.logcatWasStopped)
        await waitUntil("the poll never described the stream") { controller.logcatStatusText == "all logs" }
        let pid = try await logcatPID(stub)

        controller.logcatEntries = [LogcatEntry(
            timestamp: "09-24 12:00:00.000", pid: 1, tid: 1, level: .info, tag: "Tag", message: "shown"
        )]
        controller.stopLogcat()

        XCTAssertTrue(controller.logcatWasStopped)
        XCTAssertNil(controller.logcatSerial)
        XCTAssertEqual(controller.logcatEntries, [])
        XCTAssertEqual(controller.logcatStatusText, "")
        XCTAssertNil(controller.logcatStopReason, "a deliberate stop is not a disconnect")
        await waitUntil("the logcat child outlived the stop") { kill(pid, 0) != 0 }
    }

    func testHidingTheLogStopsTheChildAndShowingItRestarts() async throws {
        let stub = try makeLogcatStubAdb()
        let controller = LogcatController(adbClient: stub.client, status: StatusCenter(), picker: TestPicker())
        controller.packageRefreshInterval = .milliseconds(50)
        addTeardownBlock { @MainActor in controller.stopLogcat() }
        let view = UUID()

        controller.setLogShown(view, true)
        await controller.openLogcat(serial: fastSerial)
        let firstPID = try await logcatPID(stub)

        controller.setLogShown(view, false)
        XCTAssertTrue(controller.logStreamSuspended)
        await waitUntil("the logcat child outlived hiding the log") { kill(firstPID, 0) != 0 }
        let refreshes = stub.calls(containing: "pm list packages").count
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(stub.calls(containing: "pm list packages").count, refreshes, "the package refresh kept running")

        try? FileManager.default.removeItem(at: stub.directory.appendingPathComponent("logcat.pid"))
        controller.setLogShown(view, true)
        XCTAssertFalse(controller.logStreamSuspended)
        let secondPID = try await logcatPID(stub)
        XCTAssertNotEqual(secondPID, firstPID)
        XCTAssertEqual(controller.logcatSerial, fastSerial)
    }

    func testOpenIfNeededKeepsTheStreamingDevice() async throws {
        let stub = try makeLogcatStubAdb()
        let controller = LogcatController(adbClient: stub.client, status: StatusCenter(), picker: TestPicker())
        addTeardownBlock { @MainActor in controller.stopLogcat() }

        controller.openLogcatIfNeeded(serial: fastSerial)
        await waitUntil("the start never loaded its packages") { !controller.logcatPackages.isEmpty }
        controller.openLogcatIfNeeded(serial: fastSerial)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(stub.calls(containing: "pm list packages").count, 1)
    }

    func testWithoutAdbOpenOnlyRecordsTheSerial() async {
        let controller = LogcatController(adbClient: nil, status: StatusCenter(), picker: TestPicker())

        await controller.openLogcat(serial: fastSerial)

        XCTAssertEqual(controller.logcatSerial, fastSerial)
        XCTAssertFalse(controller.logcatWasStopped)
        XCTAssertEqual(controller.logcatPackages, [])
        XCTAssertNil(controller.logcatStopReason)
    }

    // MARK: - Status line

    func testTheStatusLineNamesEachStreamState() {
        XCTAssertEqual(LogcatController.describe(.idle, package: nil), "idle")
        XCTAssertEqual(LogcatController.describe(.running(pid: nil), package: nil), "all logs")
        XCTAssertEqual(
            LogcatController.describe(.running(pid: 4242), package: nil),
            "all logs",
            "without a followed package the pid is not shown"
        )
        XCTAssertEqual(
            LogcatController.describe(.running(pid: nil), package: "com.example.app"),
            "com.example.app · waiting for the app…"
        )
        XCTAssertEqual(
            LogcatController.describe(.running(pid: 4242), package: "com.example.app"),
            "com.example.app"
        )
        XCTAssertEqual(
            LogcatController.describe(.stopped(reason: "logcat exited with status 1"), package: "com.example.app"),
            "stopped: logcat exited with status 1"
        )
    }

    // MARK: - Export

    func testTheExportIsOneTimestampLevelTagLinePerEntry() {
        let text = LogcatController.logcatExportText([
            LogcatEntry(
                timestamp: "09-24 12:00:00.000", pid: 1, tid: 1, level: .error,
                tag: "AndroidRuntime", message: "FATAL EXCEPTION: main\n\tat Main.run"
            ),
            LogcatEntry(
                timestamp: "09-24 12:00:01.000", pid: 1, tid: 1, level: .warning,
                tag: "ActivityManager", message: "Process died"
            ),
        ])

        XCTAssertEqual(
            text,
            "09-24 12:00:00.000 E AndroidRuntime: FATAL EXCEPTION: main\n\tat Main.run\n"
                + "09-24 12:00:01.000 W ActivityManager: Process died",
            "a continuation line follows its entry without a header of its own"
        )
    }

    func testAnEmptyExportIsEmpty() {
        XCTAssertEqual(LogcatController.logcatExportText([]), "")
    }

    func testTheExportGoesWhereThePickerPoints() throws {
        let directory = try makeExportDirectory()
        let picker = TestPicker()
        picker.destination = directory.appendingPathComponent("picked.log")
        let status = StatusCenter()
        let controller = LogcatController(adbClient: nil, status: status, picker: picker)

        controller.exportLogcat(entries: exportEntries)

        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("picked.log"), encoding: .utf8),
            LogcatController.logcatExportText(exportEntries)
        )
        XCTAssertEqual(picker.suggestedNames.count, 1)
        let name = try XCTUnwrap(picker.suggestedNames.first)
        XCTAssertNotNil(
            name.wholeMatch(of: /devicehubpro-logcat-\d{8}-\d{6}\.log/),
            "suggested \(name)"
        )
        XCTAssertNil(status.errorMessage)
    }

    func testACancelledExportWritesNothing() throws {
        let directory = try makeExportDirectory()
        let picker = TestPicker()
        let status = StatusCenter()
        let controller = LogcatController(adbClient: nil, status: status, picker: picker)

        controller.exportLogcat(entries: exportEntries)

        XCTAssertEqual(picker.suggestedNames.count, 1, "the picker was asked")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        XCTAssertNil(status.errorMessage, "cancelling is not a failure")
    }

    func testNothingToExportAsksNothing() {
        let picker = TestPicker()
        let controller = LogcatController(adbClient: nil, status: StatusCenter(), picker: picker)

        controller.exportLogcat(entries: [])

        XCTAssertEqual(picker.suggestedNames, [])
    }

    func testAFailedExportRaisesTheWindowAlert() throws {
        let directory = try makeExportDirectory()
        let picker = TestPicker()
        picker.destination = directory
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("picked.log")
        let status = StatusCenter()
        let controller = LogcatController(adbClient: nil, status: status, picker: picker)

        controller.exportLogcat(entries: exportEntries)

        let message = try XCTUnwrap(status.errorMessage)
        XCTAssertTrue(message.hasPrefix("Log export failed: "), message)
    }

    private var exportEntries: [LogcatEntry] {
        [LogcatEntry(
            timestamp: "09-24 12:00:00.000", pid: 1, tid: 1, level: .info, tag: "ActivityManager", message: "Start proc"
        )]
    }

    private func makeExportDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogcatExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Best effort: a leftover export directory must not fail the test.
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

/// Quit stops the stream the Diagnostics tab opened, on both quit paths.
@MainActor
final class LogcatQuitTests: XCTestCase {
    func testPrepareForTerminationStopsLogcat() async throws {
        let (model, pid) = try await openedModel()

        await model.prepareForTermination(timeout: .seconds(2))

        XCTAssertTrue(model.logcat.logcatWasStopped)
        XCTAssertNil(model.logcat.logcatSerial)
        await waitUntil("the logcat child outlived quit") { kill(pid, 0) != 0 }
    }

    func testTheTerminationBackstopStopsLogcat() async throws {
        let (model, pid) = try await openedModel()

        model.terminationBackstop()

        XCTAssertTrue(model.logcat.logcatWasStopped)
        XCTAssertNil(model.logcat.logcatSerial)
        await waitUntil("the logcat child outlived quit") { kill(pid, 0) != 0 }
    }

    private func openedModel() async throws -> (AppModel, pid_t) {
        let stub = try makeLogcatStubAdb()
        let model = AppModel.testing(adb: stub.client)
        addTeardownBlock { @MainActor in model.logcat.stopLogcat() }
        await model.logcat.openLogcat(serial: "emulator-5556")
        return (model, try await logcatPID(stub))
    }
}

// MARK: - Stub adb

extension XCTestCase {
    /// A fake adb for the logcat tests: `emulator-5554`'s package list takes
    /// half a second, any other answers at once, and `logcat` writes its pid
    /// next to the stub, then idles until it is stopped.
    fileprivate func makeLogcatStubAdb() throws -> StubAdb {
        try makeStubAdb(arms: """
          "-s emulator-5554 shell pm list packages"*)
            sleep 0.5
            printf 'package:com.example.slow\\n' ;;
          *"pm list packages"*)
            printf 'package:com.example.fast\\n' ;;
          *" logcat "*)
            printf '%s\\n' "$$" > "$(dirname "$0")/logcat.pid"
            exec sleep 30 ;;
        """)
    }

    /// The pid of the stub's `logcat` child, once it has started.
    @MainActor
    fileprivate func logcatPID(_ stub: StubAdb) async throws -> pid_t {
        let pidURL = stub.directory.appendingPathComponent("logcat.pid")
        func read() -> pid_t? {
            (try? String(contentsOf: pidURL, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        await waitUntil("the stub's logcat never started") { read() != nil }
        return try XCTUnwrap(read())
    }
}
