import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// What the app keeps of the errors it shows, for a problem report
/// (`StatusCenter.problemLog`): the message, the details that arrive after it,
/// and the states that never pass through an alert.
@MainActor
final class ProblemLogRecordingTests: XCTestCase {
    private func center() -> (StatusCenter, RecentProblemStore) {
        let log = RecentProblemStore(fileURL: nil)
        let status = StatusCenter()
        status.problemLog = log
        return (status, log)
    }

    /// An error is written first and its details after it (the alert's "Show
    /// Details" text): they are one entry.
    func testAnErrorAndItsDetailsAreOneEntry() {
        let (status, log) = center()

        status.errorMessage = "Pixel_8_Pro did not come online in time."
        status.errorDetails = "INFO    | Storing crashdata\nWARNING | QEMU main loop exits abnormally with code 1"

        let entries = log.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].message, "Pixel_8_Pro did not come online in time.")
        XCTAssertEqual(entries[0].details, ["INFO    | Storing crashdata", "WARNING | QEMU main loop exits abnormally with code 1"])
        XCTAssertEqual(entries[0].count, 1)
    }

    /// The details go to the error that was shown last, not to an older one
    /// with the same text.
    func testDetailsAttachToTheLatestError() {
        let (status, log) = center()

        status.errorMessage = "First"
        status.errorMessage = "Second"
        status.errorDetails = "about the second"

        let entries = log.entries()
        XCTAssertEqual(entries.map(\.message), ["Second", "First"], "newest first")
        XCTAssertEqual(entries[0].details, ["about the second"])
        XCTAssertNil(entries[1].details)
    }

    /// The same message within a minute is counted, not repeated.
    func testTheSameMessageWithinAMinuteIsCounted() {
        let (status, log) = center()

        status.errorMessage = "Emulator not responding"
        status.errorMessage = nil
        status.errorMessage = "Emulator not responding"

        let entries = log.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].count, 2)
    }

    /// Dismissing an alert (writing nil) records nothing, and details with no
    /// error shown belong to nothing.
    func testClearingAnErrorAndOrphanDetailsRecordNothing() {
        let (status, log) = center()

        status.errorMessage = nil
        status.errorDetails = "no error shown"

        XCTAssertEqual(log.entries(), [])
    }

    /// A state the app shows some other way (the stalled screen, the stuck
    /// emulator card) is kept by `noteProblem`.
    func testNoteProblemRecordsAStateThatNeverPassesThroughAnAlert() {
        let (status, log) = center()

        status.noteProblem("The emulator isn\u{2019}t sending its screen (emulator-5554).")

        XCTAssertEqual(log.entries().map(\.message), ["The emulator isn\u{2019}t sending its screen (emulator-5554)."])
        XCTAssertNil(status.errorMessage, "no alert is raised")
    }

    /// A center built on its own (most tests) keeps nothing and still works.
    func testACenterWithoutALogRecordsNothing() {
        let status = StatusCenter()

        status.errorMessage = "Anything"
        status.errorDetails = "details"
        status.noteProblem("Anything else")

        XCTAssertNil(status.problemLog)
        XCTAssertEqual(status.errorMessage, "Anything")
    }

    /// The phones connected when an error is shown are kept with it: the report is made after one was unplugged.
    func testTheDevicesConnectedWhenAnErrorIsShownAreKeptBesideIt() {
        let (status, log) = center()
        var connected = RecentProblemIdentifiers(phones: [["R58M12345AB"]])
        status.problemIdentifiers = { connected }

        status.errorMessage = "adb -s R58M12345AB reboot failed (1): adb: device 'R58M12345AB' not found"
        connected = RecentProblemIdentifiers(phones: [["ZX1G22ABCD"]])
        status.noteProblem("Emulator not responding (emulator-5554): it stopped answering its controls.")

        XCTAssertEqual(log.identifiers().phones, [["ZX1G22ABCD"], ["R58M12345AB"]])
    }

    /// The model's center and each workspace's read the inventory when the error is written, and the unplugged phone
    /// stays known to the log after the inventory forgot it.
    func testTheInventoryOfTheModelFeedsEveryCenter() {
        let environment = AppEnvironment.testing()
        let model = AppModel(environment: environment)
        let second = DeviceWorkspace(services: model.services)
        model.inventory.setRealDevices([
            AndroidDevice(serial: "R58M12345AB", state: "device"),
            AndroidDevice(serial: "ZX1G22ABCD", state: "device"),
        ])

        model.status.errorMessage = "From the app"
        second.status.errorMessage = "From a second window"
        model.inventory.setRealDevices([])
        model.workspace.status.errorMessage = "After the phones left"

        XCTAssertEqual(
            Set(environment.recentProblems.identifiers().phones.joined()),
            ["R58M12345AB", "ZX1G22ABCD"]
        )
        XCTAssertEqual(environment.recentProblems.entries().count, 3)
    }

    /// The model's center and each workspace's own write to the one log of the
    /// environment, so an error in any window reaches the report.
    func testTheModelAndEveryWorkspaceShareTheEnvironmentsLog() {
        let environment = AppEnvironment.testing()
        let model = AppModel(environment: environment)
        let second = DeviceWorkspace(services: model.services)

        model.status.errorMessage = "From the app"
        model.workspace.status.errorMessage = "From the first window"
        second.status.errorMessage = "From a second window"

        XCTAssertEqual(
            environment.recentProblems.entries().map(\.message),
            ["From a second window", "From the first window", "From the app"]
        )
    }
}
