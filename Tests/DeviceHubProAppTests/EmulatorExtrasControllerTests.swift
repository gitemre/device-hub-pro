import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// The extended controls on their own: what a device switch forgets and
/// what it keeps, the port gate in front of every action, the draft check,
/// and the model's old names over the one controller.
@MainActor
final class EmulatorExtrasControllerTests: XCTestCase {
    /// Nothing can listen here (port 0). The tests that set a port stop
    /// before any call goes out, so nothing reaches an emulator.
    private static let unusedPort = EmulatorManager.unreachableGrpcPort

    private func makeExtras(
        port: Int? = nil
    ) -> (extras: EmulatorExtrasController, context: ActiveDeviceContext, status: StatusCenter) {
        let context = ActiveDeviceContext()
        context.port = port
        let status = StatusCenter()
        return (EmulatorExtrasController(context: context, status: status), context, status)
    }

    /// `detach()` forgets exactly the VM pause, the readings and the primed
    /// sensor; the user's typed drafts and sensor choice carry over to the
    /// next device.
    func testDetachResetsOnlyThePerDeviceState() {
        let (extras, _, _) = makeExtras()
        // Primes the gyroscope; the refresh it starts finds no port.
        extras.selectSensor(.gyroscope)
        XCTAssertEqual(extras.primedSensor, .gyroscope)
        extras.sensorReadings = [.gyroscope: [0.1, 0.2, 0.3]]
        extras.isVmPaused = true
        extras.sensorDraft = ["1.000", "2.000", "3.000"]
        extras.callNumber = "5551234"
        extras.smsFrom = "5550000"
        extras.smsText = "Hello"
        extras.emulatorPhoneNumber = "5559876"
        extras.fingerprintTouchId = "3"

        extras.detach()

        XCTAssertFalse(extras.isVmPaused)
        XCTAssertTrue(extras.sensorReadings.isEmpty)
        XCTAssertNil(extras.primedSensor)
        XCTAssertEqual(extras.selectedSensor, .gyroscope)
        XCTAssertEqual(extras.sensorDraft, ["1.000", "2.000", "3.000"])
        XCTAssertEqual(extras.callNumber, "5551234")
        XCTAssertEqual(extras.smsFrom, "5550000")
        XCTAssertEqual(extras.smsText, "Hello")
        XCTAssertEqual(extras.emulatorPhoneNumber, "5559876")
        XCTAssertEqual(extras.fingerprintTouchId, "3")
    }

    /// Without a port (a physical device, or nothing mirrored) every action
    /// returns before it does anything: no poll, no alert and no state change;
    /// a user's action says the controls are not connected yet.
    func testWithoutAPortEveryActionIsANoOp() async {
        let (extras, _, status) = makeExtras()
        extras.callNumber = "5551234"
        extras.smsFrom = "5550000"
        extras.smsText = "Hello"
        extras.emulatorPhoneNumber = "5559876"
        extras.fingerprintTouchId = "3"
        // One value short: the port gate comes before the draft check.
        extras.sensorDraft = ["1", "2"]

        extras.attach()
        await extras.refreshSensor()
        await extras.refreshSensorDraft()
        await extras.applySensorValues()
        await extras.placeIncomingCall()
        await extras.sendSMS()
        await extras.applyEmulatorPhoneNumber()
        await extras.toggleVmPause()
        await extras.touchFingerprint()

        XCTAssertNil(extras.sensorPollTask, "no port, no poll")
        XCTAssertNil(status.errorMessage)
        XCTAssertEqual(status.statusMessage, "The emulator\u{2019}s controls aren\u{2019}t connected yet.")
        XCTAssertFalse(extras.isVmPaused)
        XCTAssertTrue(extras.sensorReadings.isEmpty)
        XCTAssertNil(extras.primedSensor)
        XCTAssertEqual(extras.sensorDraft, ["1", "2"])
    }

    /// A new session's poll replaces the previous one, and `stopPolling()`
    /// ends it. Each poll is cancelled before the main actor is given up,
    /// so none of them ever reads the port.
    func testAttachReplacesThePollAndStopPollingEndsIt() throws {
        let (extras, _, _) = makeExtras(port: Self.unusedPort)

        extras.attach()
        let first = try XCTUnwrap(extras.sensorPollTask)
        extras.attach()
        let second = try XCTUnwrap(extras.sensorPollTask)
        XCTAssertTrue(first.isCancelled, "the previous session's poll must not keep running")
        XCTAssertFalse(second.isCancelled)

        extras.stopPolling()
        XCTAssertTrue(second.isCancelled)
        XCTAssertNil(extras.sensorPollTask)
    }

    /// A draft that does not parse to one number per axis is refused with
    /// the alert before anything is sent to the emulator.
    func testAWrongAxisCountSetsTheError() async {
        let (extras, _, status) = makeExtras(port: Self.unusedPort)
        extras.selectedSensor = .acceleration
        // A decimal comma parses; the word does not, which leaves two values.
        extras.sensorDraft = ["1,5", "2", "three"]

        await extras.applySensorValues()

        XCTAssertEqual(status.errorMessage, "Enter 3 numeric value(s).")
        XCTAssertNil(status.statusMessage)
        XCTAssertTrue(extras.sensorReadings.isEmpty)

        status.errorMessage = nil
        extras.selectedSensor = .temperature
        extras.sensorDraft = ["21", "22"]

        await extras.applySensorValues()

        XCTAssertEqual(status.errorMessage, "Enter 1 numeric value(s).")
        XCTAssertTrue(extras.sensorReadings.isEmpty)
    }

    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var _items: [String] = []
        var items: [String] { lock.withLock { _items } }
        func add(_ item: String) { lock.withLock { _items.append(item) } }
    }

    /// The sheets close only on a true answer: a sender that fails leaves the
    /// answer false with the alert; one that succeeds answers true with a
    /// flash and no alert.
    func testTelephonyFailureKeepsTheSheetOpenAndSuccessClosesIt() async {
        let (extras, _, status) = makeExtras(port: Self.unusedPort)
        let sent = Sent()
        extras.callNumber = "5551234"
        extras.smsFrom = "5550000"
        extras.smsText = "Hello"
        extras.emulatorPhoneNumber = "5559876"

        extras.callSender = { _, _ in false }
        extras.smsSender = { _, _, _ in false }
        extras.phoneNumberSender = { _, _ in false }
        let failed = await [extras.placeIncomingCall(), extras.sendSMS(), extras.applyEmulatorPhoneNumber()]
        XCTAssertEqual(failed, [false, false, false])
        XCTAssertEqual(status.errorMessage, "The emulator rejected the phone number.")
        status.errorMessage = nil
        _ = await extras.placeIncomingCall()
        XCTAssertEqual(status.errorMessage, "The emulator rejected the call.")
        status.errorMessage = nil
        _ = await extras.sendSMS()
        XCTAssertEqual(status.errorMessage, "The emulator rejected the SMS.")
        XCTAssertEqual(extras.callNumber, "5551234", "the typed values stay for another try")

        status.errorMessage = nil
        extras.callSender = { _, number in sent.add("call \(number)"); return true }
        extras.smsSender = { _, from, text in sent.add("sms \(from) \(text)"); return true }
        extras.phoneNumberSender = { _, number in sent.add("number \(number)"); return true }
        let ok = await [extras.placeIncomingCall(), extras.sendSMS(), extras.applyEmulatorPhoneNumber()]
        XCTAssertEqual(ok, [true, true, true])
        XCTAssertNil(status.errorMessage)
        XCTAssertEqual(sent.items, ["call 5551234", "sms 5550000 Hello", "number 5559876"])
    }

    /// Without a device the action sends nothing, answers false (the sheet
    /// stays open) and says why.
    func testTelephonyWithoutADeviceSendsNothingAndSaysWhy() async {
        let (extras, _, status) = makeExtras()
        let sent = Sent()
        extras.callNumber = "5551234"
        extras.callSender = { _, _ in sent.add("call"); return true }
        extras.smsFrom = "5550000"
        extras.smsText = "Hello"
        extras.smsSender = { _, _, _ in sent.add("sms"); return true }
        extras.emulatorPhoneNumber = "5559876"
        extras.phoneNumberSender = { _, _ in sent.add("number"); return true }

        let answers = await [extras.placeIncomingCall(), extras.sendSMS(), extras.applyEmulatorPhoneNumber()]

        XCTAssertEqual(answers, [false, false, false])
        XCTAssertTrue(sent.items.isEmpty)
        XCTAssertEqual(status.statusMessage, "The emulator\u{2019}s controls aren\u{2019}t connected yet.")
        XCTAssertNil(status.errorMessage)
    }

    /// The model's old names read and write the one controller, including
    /// the Controls tab's per-axis binding, and the teardown hub detaches it.
    func testModelNamesForwardToTheControllerAndTeardownDetachesIt() {
        let model = AppModel.testing()

        model.workspace.extras.callNumber = "5551234"
        XCTAssertEqual(model.extras.callNumber, "5551234")
        model.extras.isVmPaused = true
        XCTAssertTrue(model.workspace.extras.isVmPaused)
        model.workspace.extras.sensorDraft[1] = "9"
        XCTAssertEqual(model.extras.sensorDraft, ["0", "9", "0"])

        model.workspace.extras.selectSensor(.light)
        XCTAssertEqual(model.extras.selectedSensor, .light)
        XCTAssertEqual(model.workspace.extras.sensorDraft, ["0.000"])
        XCTAssertEqual(model.extras.primedSensor, .light)

        model.stopMirror()

        XCTAssertFalse(model.workspace.extras.isVmPaused)
        XCTAssertNil(model.extras.primedSensor, "the next device primes its own draft")
        XCTAssertEqual(model.workspace.extras.selectedSensor, .light)
        XCTAssertEqual(model.workspace.extras.callNumber, "5551234")
    }
}
