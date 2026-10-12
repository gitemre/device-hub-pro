import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The Report a Problem sheet's model, on a Mac made of a temporary folder
/// (`ProblemReportWorld`): the recorded `ps` of a Mac with an adb server and a
/// running emulator, a fake adb that answers the emulator's three reads from the
/// real captures, and a model whose inventory holds that emulator and a phone.
@MainActor
final class ProblemReportSheetModelTests: XCTestCase {
    private func readySheet(
        _ world: ProblemReportWorld,
        model: AppModel? = nil,
        subject: ProblemReport.Subject? = nil
    ) async throws -> SheetHarness {
        let harness = SheetHarness(model: model ?? world.makeModel(), subject: subject)
        XCTAssertEqual(harness.sheet.phase, .collecting)
        XCTAssertFalse(harness.sheet.isReady)
        harness.sheet.start()
        await waitUntil(timeout: 15, "the report never became ready") { harness.sheet.isReady }
        return harness
    }

    // MARK: Collecting

    /// The sheet collects and asks only the emulator, with the three allowed
    /// reads: never the phone, never `devices` (the inventory is the source),
    /// never a restart.
    func testTheSheetReachesReadyAskingOnlyTheEmulator() async throws {
        let world = try ProblemReportWorld(test: self)
        let harness = try await readySheet(world)
        let prepared = try XCTUnwrap(harness.sheet.prepared)

        let calls = world.adb.calls
        XCTAssertEqual(Set(calls), [
            "-s emulator-5554 emu avd name",
            "-s emulator-5554 shell getprop ro.boot.qemu.avd_name",
            "-s emulator-5554 shell getprop sys.boot_completed",
        ])
        XCTAssertEqual(calls.count, 3)
        let text = calls.joined(separator: "\n").lowercased()
        XCTAssertFalse(text.contains(ProblemReportWorld.phoneSerial), "no call names the phone")
        XCTAssertTrue(world.adb.calls(containing: "devices").isEmpty, "the app's inventory is the source of the rows")
        XCTAssertFalse(text.contains("kill-server"))
        XCTAssertFalse(text.contains("start-server"))

        let report = prepared.report
        XCTAssertEqual(report.producer, .app)
        XCTAssertEqual(report.android.devicesSource, "app inventory")
        let emulator = try XCTUnwrap(report.android.runningEmulators.first)
        XCTAssertEqual(emulator.serial, "emulator-5554")
        XCTAssertEqual(emulator.adbState, "device")
        XCTAssertEqual(emulator.console.outcome, .answered)
        XCTAssertEqual(emulator.console.name, "Pixel_9_Pro_Fold")
        XCTAssertEqual(report.android.phones.map(\.alias), ["phone-1"])
        XCTAssertFalse(prepared.markdown.lowercased().contains(ProblemReportWorld.phoneSerial), "the phone's serial is aliased")
        XCTAssertNotNil(report.app.preferences, "the app's own state is in the report")
    }

    /// Collecting writes nothing on the Mac (the problem log is the one writer,
    /// and it is not part of collecting).
    func testCollectingLeavesTheHomeAsItFoundIt() async throws {
        let world = try ProblemReportWorld(test: self)
        let before = world.listing()

        _ = try await readySheet(world)

        XCTAssertEqual(world.listing(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.home.appendingPathComponent("Library/Logs/DeviceHubPro").path))
    }

    /// The error the user is reporting is the report's subject, and the
    /// recent problems come from the environment's log.
    func testTheSubjectAndTheRecentProblemsAreInTheReport() async throws {
        let world = try ProblemReportWorld(test: self)
        let model = world.makeModel()
        model.status.errorMessage = "Pixel_8_Pro did not come online in time."
        let subject = ProblemReport.Subject(
            message: "Pixel_8_Pro did not come online in time.",
            details: ["INFO | one"],
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let harness = try await readySheet(world, model: model, subject: subject)
        let report = try XCTUnwrap(harness.sheet.prepared?.report)

        XCTAssertEqual(report.subject?.message, "Pixel_8_Pro did not come online in time.")
        XCTAssertEqual(report.recentProblems.map(\.message), ["Pixel_8_Pro did not come online in time."])
    }

    // MARK: Copy, save, open

    func testCopyPutsTheReportOnThePasteboard() async throws {
        let world = try ProblemReportWorld(test: self)
        let harness = try await readySheet(world)

        harness.sheet.copy()

        XCTAssertEqual(harness.pasteboard.text, harness.sheet.prepared?.markdown)
        XCTAssertTrue(harness.pasteboard.text?.hasPrefix("<!-- dhp-report v1 -->") == true)
        XCTAssertEqual(harness.status.statusMessage, "Problem report copied")
    }

    func testSaveWritesATextFileWhereThePickerSays() async throws {
        let world = try ProblemReportWorld(test: self)
        let harness = try await readySheet(world)
        let destination = world.root.appendingPathComponent("report.txt")
        harness.picker.destination = destination

        harness.sheet.save()

        let name = try XCTUnwrap(harness.picker.suggestedNames.first)
        XCTAssertEqual(name, "device-hub-pro-report-\(Self.stamp(Date(timeIntervalSince1970: 1_800_000_000))).txt")
        XCTAssertTrue(name.hasPrefix("device-hub-pro-report-"))
        XCTAssertTrue(name.hasSuffix(".txt"))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), harness.sheet.prepared?.markdown)
        XCTAssertEqual(harness.status.statusMessage, "Problem report saved \u{2014} report.txt")
    }

    func testCancellingTheSavePanelWritesNothing() async throws {
        let world = try ProblemReportWorld(test: self)
        let harness = try await readySheet(world)
        harness.picker.destination = nil
        let before = world.listing()

        harness.sheet.save()

        XCTAssertEqual(harness.picker.suggestedNames.count, 1)
        XCTAssertEqual(world.listing(), before)
        XCTAssertNil(harness.status.statusMessage)
        XCTAssertNil(harness.status.errorMessage)
    }

    func testAFailedSaveSaysSo() async throws {
        let world = try ProblemReportWorld(test: self)
        let harness = try await readySheet(world)
        harness.picker.destination = world.root.appendingPathComponent("no-such-folder/report.txt")

        harness.sheet.save()

        XCTAssertTrue(harness.status.errorMessage?.hasPrefix("Couldn\u{2019}t save the report: ") == true, "\(String(describing: harness.status.errorMessage))")
    }

    /// Open GitHub Issue copies the report, then opens the form once: github.com,
    /// the new-issue path and the bug report template.
    func testOpenIssueCopiesTheReportAndOpensTheForm() async throws {
        let world = try ProblemReportWorld(test: self)
        let harness = try await readySheet(world)

        harness.sheet.openIssue()

        XCTAssertEqual(harness.pasteboard.text, harness.sheet.prepared?.markdown)
        XCTAssertEqual(harness.opened.urls.count, 1)
        let url = try XCTUnwrap(harness.opened.urls.first)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/gitemre/device-hub-pro/issues/new")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "template" }?.value, "bug_report.yml")
        let note = try XCTUnwrap(harness.sheet.footerNote)
        XCTAssertTrue([ProblemReportSheetModel.openedFilledNote, ProblemReportSheetModel.openedPasteNote].contains(note))
        let link = ProblemReportIssueLink.link(for: try XCTUnwrap(harness.sheet.prepared))
        XCTAssertEqual(note, link.includesReport ? ProblemReportSheetModel.openedFilledNote : ProblemReportSheetModel.openedPasteNote)
    }

    /// Nothing is offered before the report is ready: the buttons are disabled
    /// and the model does nothing if they are called anyway.
    func testNothingIsCopiedSavedOrOpenedBeforeTheReportIsReady() throws {
        let world = try ProblemReportWorld(test: self)
        let harness = SheetHarness(model: world.makeModel())

        harness.sheet.copy()
        harness.sheet.save()
        harness.sheet.openIssue()

        XCTAssertNil(harness.pasteboard.text)
        XCTAssertEqual(harness.picker.suggestedNames, [])
        XCTAssertEqual(harness.opened.urls, [])
        XCTAssertNil(harness.sheet.footerNote)
    }

    /// Closing the sheet stops the collection: nothing is shown after it.
    func testClosingTheSheetStopsTheCollection() async throws {
        let world = try ProblemReportWorld(test: self)
        let harness = SheetHarness(model: world.makeModel())

        harness.sheet.start()
        harness.sheet.cancel()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(harness.sheet.phase, .collecting)
    }

    // MARK: Privacy

    /// What the user never sees in a report: the signing team, the enabled
    /// devices' identifiers and the `DHP_IPHONE_UDID` value are scrubbed even
    /// where an error message quoted them, and the preferences carry yes/no and
    /// counts only.
    func testTeamAndDeviceIdentifiersNeverReachTheReport() async throws {
        let world = try ProblemReportWorld(test: self)
        let defaults = UserDefaults.scratch()
        defaults.set("ABCDE12345", forKey: AppPreferences.Keys.physicalControlTeamID)
        defaults.set(["00000000-0000000000000000"], forKey: AppPreferences.Keys.enabledPhysicalAppleDevices)
        var launch = LaunchOptions.none
        launch.iphoneUDID = "TESTPHONE-UDID-0001"
        let model = world.makeModel(launch: launch, defaults: defaults)
        model.services.environment.recentProblems.record(
            message: "Signing failed for team ABCDE12345 on 00000000-0000000000000000 and TESTPHONE-UDID-0001."
        )

        let harness = try await readySheet(world, model: model)
        let markdown = try XCTUnwrap(harness.sheet.prepared?.markdown)

        for secret in ["ABCDE12345", "00000000-0000000000000000", "TESTPHONE-UDID-0001"] {
            XCTAssertFalse(markdown.lowercased().contains(secret.lowercased()), "\(secret) is in the report")
        }
        XCTAssertTrue(markdown.contains("Signing failed for team"), "the problem itself is kept")
        XCTAssertTrue(markdown.contains("\"developmentTeamSet\" : true"))
        XCTAssertTrue(markdown.contains("\"enabledPhysicalDeviceCount\" : 1"))
    }

    /// An error that named a phone is reported after the phone was unplugged: the serial is in no inventory any more,
    /// and still never reaches the report (Markdown, subject or issue link).
    func testAnUnpluggedPhonesSerialNeverReachesTheReport() async throws {
        let world = try ProblemReportWorld(test: self)
        let model = world.makeModel()
        let serial = "R58M12345AB"
        let error = "adb -s \(serial) reboot failed (1): adb: device '\(serial)' not found"
        // Recorded while the phone was connected (the center keeps who is connected with the error).
        model.inventory.setRealDevices([.online("emulator-5554"), AndroidDevice(serial: serial, state: "device")])
        model.workspace.status.errorMessage = "Could not open the link on \(serial): no activity found"
        model.workspace.status.errorMessage = error
        model.inventory.setRealDevices([.online("emulator-5554")])
        XCTAssertFalse(model.problemReportState().devices.contains { $0.serial == serial }, "the phone is gone")

        let subject = ProblemReport.Subject(message: error, occurredAt: Date())
        let harness = try await readySheet(world, model: model, subject: subject)
        let prepared = try XCTUnwrap(harness.sheet.prepared)

        let everything = prepared.markdown + ProblemReportIssueLink.link(for: prepared).url.absoluteString.removingPercentEncoding.orEmpty
        XCTAssertFalse(everything.lowercased().contains(serial.lowercased()), "the serial left the Mac")
        XCTAssertTrue(prepared.markdown.contains("adb -s phone-"), "the error itself is kept")
        XCTAssertTrue(prepared.markdown.contains("Could not open the link on phone-"))
    }

    // MARK: Helpers

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
