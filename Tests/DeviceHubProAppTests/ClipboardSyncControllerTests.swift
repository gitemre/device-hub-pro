import Foundation
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The clipboard sync's physical-device paths and its loop, on a fake scrcpy
/// session and an in-memory pasteboard: no phone, no emulator, and never
/// the Mac's own clipboard. The emulator paths talk gRPC to a live console,
/// and the real-phone checks (both directions over the control socket) are
/// on the morning checklist.
@MainActor
final class ClipboardSyncControllerTests: XCTestCase {
    private static let serial = "phone-serial-1"
    private static let notSharedYet =
        "The device has not shared its clipboard yet. Copy something on the device, then try again."

    /// The Mac side as the sync sees it: the text, how often it was read and
    /// every text written to it.
    @MainActor
    private final class RecordingPasteboard: MacPasteboard {
        var text: String?
        private(set) var reads = 0
        private(set) var writes: [String] = []

        func string() -> String? {
            reads += 1
            return text
        }

        func setString(_ text: String) {
            self.text = text
            writes.append(text)
        }

        func setPNG(_ png: Data) {
            text = nil
        }
    }

    private struct Harness {
        let controller: ClipboardSyncController
        let context: ActiveDeviceContext
        let status: StatusCenter
        let pasteboard: RecordingPasteboard
    }

    /// A controller on a physical device (`serial`, no port) that polls
    /// every 10 ms, with auto-sync as given.
    private func makeHarness(autoSync: Bool) -> Harness {
        let context = ActiveDeviceContext()
        context.serial = Self.serial
        let preferences = AppPreferences(defaults: .scratch())
        preferences.setClipboardAutoSync(autoSync)
        let status = StatusCenter()
        let pasteboard = RecordingPasteboard()
        let controller = ClipboardSyncController(
            context: context,
            preferences: preferences,
            status: status,
            pasteboard: pasteboard,
            pollInterval: .milliseconds(10)
        )
        addTeardownBlock { @MainActor in controller.detach() }
        return Harness(controller: controller, context: context, status: status, pasteboard: pasteboard)
    }

    /// Simulates one tick of the app-level Mac-pasteboard poll
    /// (`AppServices.clipboardPoll`): reads the Mac side
    /// once and fans it into the controller, the way the real poll fans one
    /// read out to every workspace's controller.
    private func simulatePoll(_ harness: Harness) {
        harness.controller.applyMacPasteboardPoll(harness.pasteboard.string())
    }

    // MARK: Device → Mac

    /// scrcpy reports the clipboard of a device that is no longer the active
    /// one (a late push after a switch): nothing is written, and nothing is
    /// kept for Pull either.
    func testAReceiveForANonActiveSerialIsIgnored() async {
        let harness = makeHarness(autoSync: true)
        harness.pasteboard.text = "on the mac"

        harness.controller.receive("from the other phone", serial: "phone-serial-2")

        XCTAssertEqual(harness.pasteboard.text, "on the mac")
        XCTAssertTrue(harness.pasteboard.writes.isEmpty)
        // Kept, it would answer a Pull on that session.
        await harness.controller.pull(physical: FakePhysicalSession(serial: "phone-serial-2"))
        XCTAssertEqual(harness.status.errorMessage, Self.notSharedYet)
        XCTAssertTrue(harness.pasteboard.writes.isEmpty)
    }

    /// With auto-sync off the device's clipboard does not replace the Mac's,
    /// but it is kept, so Pull can still copy it.
    func testWithAutoSyncOffTheTextIsKeptForPullAndThePasteboardIsUntouched() async {
        let harness = makeHarness(autoSync: false)
        let phone = FakePhysicalSession(serial: Self.serial)
        harness.pasteboard.text = "on the mac"

        harness.controller.receive("copied on the phone", serial: Self.serial)
        XCTAssertEqual(harness.pasteboard.text, "on the mac")
        XCTAssertTrue(harness.pasteboard.writes.isEmpty)

        await harness.controller.pull(physical: phone)
        XCTAssertEqual(harness.pasteboard.writes, ["copied on the phone"])
        XCTAssertNil(harness.status.errorMessage)
        XCTAssertEqual(harness.status.statusMessage, "Clipboard pulled from the device")
    }

    /// With auto-sync on the device's clipboard replaces the Mac's once: a
    /// repeated report writes nothing, and the Mac poll does not send the
    /// text it just wrote back to the device.
    func testWithAutoSyncOnThePasteboardIsWrittenOnceAndNotEchoedBack() async {
        let harness = makeHarness(autoSync: true)
        let phone = FakePhysicalSession(serial: Self.serial)
        harness.pasteboard.text = "on the mac"
        harness.controller.attach(physical: phone)

        harness.controller.receive("copied on the phone", serial: Self.serial)
        XCTAssertEqual(harness.pasteboard.writes, ["copied on the phone"])
        harness.controller.receive("copied on the phone", serial: Self.serial)
        XCTAssertEqual(harness.pasteboard.writes, ["copied on the phone"])

        simulatePoll(harness)
        XCTAssertEqual(phone.clipboardWrites, [], "the device's own text went back to it")
    }

    // MARK: Mac → device

    /// The Mac poll (now the app-level poll's fan-out)
    /// sends a text only when it changed since sync started (the text
    /// already there is seeded, not sent) and only while the control
    /// socket is up; the text waits for the socket, and is sent once.
    func testMacToDeviceOnlyWhenTheTextChangedAndTheControlSocketIsUp() async throws {
        let harness = makeHarness(autoSync: true)
        let phone = FakePhysicalSession(serial: Self.serial)
        harness.pasteboard.text = "before sync"
        harness.controller.attach(physical: phone)

        simulatePoll(harness)
        XCTAssertEqual(phone.clipboardWrites, [], "the seeded text was sent")

        phone.usesControlSocket = false
        harness.pasteboard.text = "copied on the mac"
        simulatePoll(harness)
        XCTAssertEqual(phone.clipboardWrites, [], "sent without the control socket")

        phone.usesControlSocket = true
        simulatePoll(harness)
        XCTAssertEqual(
            phone.clipboardWrites,
            [FakePhysicalSession.ClipboardWrite(text: "copied on the mac", paste: false)]
        )
        // A repeated poll of the same text sends nothing further.
        simulatePoll(harness)
        XCTAssertEqual(phone.clipboardWrites.count, 1)
    }

    /// A new Mac text the device already holds (its last push, kept while
    /// auto-sync was off) is not sent to it again once auto-sync is on.
    func testAMacTextTheDeviceAlreadyHoldsIsNotSentToIt() async {
        let harness = makeHarness(autoSync: false)
        let phone = FakePhysicalSession(serial: Self.serial)
        harness.pasteboard.text = "on the mac"
        harness.controller.receive("copied on the phone", serial: Self.serial)

        harness.controller.setAutoSync(true, physical: phone)
        harness.pasteboard.text = "copied on the phone"
        simulatePoll(harness)

        XCTAssertEqual(phone.clipboardWrites, [])
    }

    // MARK: Pull

    /// Pull on a physical device answers from the last clipboard it pushed;
    /// before any push it says so and leaves the Mac clipboard alone.
    func testPullBeforeAnyPushSaysTheDeviceHasNotSharedItsClipboard() async {
        let harness = makeHarness(autoSync: false)
        let phone = FakePhysicalSession(serial: Self.serial)
        harness.pasteboard.text = "on the mac"

        await harness.controller.pull(physical: phone)

        XCTAssertEqual(harness.status.errorMessage, Self.notSharedYet)
        XCTAssertEqual(harness.pasteboard.text, "on the mac")
        XCTAssertTrue(harness.pasteboard.writes.isEmpty)
    }

    // MARK: Loop lifecycle

    /// `detach` (the teardown's) stops auto-sync's Mac → device push — a
    /// later app-level poll fan-out reaches this controller and does
    /// nothing — but keeps what the sync saw, as the model did: a repeated
    /// device report still writes nothing, and Pull still answers from the
    /// last push.
    func testDetachStopsTheLoopAndKeepsTheEchoState() async throws {
        let harness = makeHarness(autoSync: true)
        let phone = FakePhysicalSession(serial: Self.serial)
        harness.controller.attach(physical: phone)
        harness.controller.receive("copied on the phone", serial: Self.serial)
        XCTAssertEqual(harness.pasteboard.writes, ["copied on the phone"])

        harness.controller.detach()
        harness.pasteboard.text = "copied on the mac"
        simulatePoll(harness)
        XCTAssertEqual(phone.clipboardWrites, [], "detach stopped auto-sync's Mac → device push")

        harness.controller.receive("copied on the phone", serial: Self.serial)
        XCTAssertEqual(harness.pasteboard.text, "copied on the mac", "detach forgot the device side")
        XCTAssertEqual(harness.pasteboard.writes, ["copied on the phone"])

        await harness.controller.pull(physical: phone)
        XCTAssertNil(harness.status.errorMessage)
        XCTAssertEqual(harness.pasteboard.text, "copied on the phone", "detach forgot the last push")
    }

    /// Without a port there is no emulator to poll, and without a physical
    /// session nothing to push to: no loop starts, so nothing reads the Mac
    /// pasteboard.
    func testWithNoPortNoLoopStarts() async throws {
        let harness = makeHarness(autoSync: true)
        XCTAssertNil(harness.context.port)

        harness.controller.attach(physical: nil)
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(harness.pasteboard.reads, 0)
    }

    /// With auto-sync off, attaching a device starts no loop — and a
    /// workspace with sync off gets nothing from the app-level Mac-pasteboard
    /// poll's fan-out either: `applyMacPasteboardPoll`
    /// no-ops without the preference on.
    func testWithAutoSyncOffAttachStartsNoLoop() async throws {
        let harness = makeHarness(autoSync: false)
        let phone = FakePhysicalSession(serial: Self.serial)
        harness.pasteboard.text = "copied on the mac"

        harness.controller.attach(physical: phone)
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(harness.pasteboard.reads, 0)
        XCTAssertEqual(phone.clipboardWrites, [])

        simulatePoll(harness)
        XCTAssertEqual(phone.clipboardWrites, [], "sync is off: the poll fan-out reaches this workspace and does nothing")
    }

    // MARK: Model wiring

    /// The model's entry points reach the controller with the active
    /// physical session: Send goes over the fake's control socket, a pushed
    /// clipboard comes back through Pull, and Back takes the same seam.
    func testTheModelSyncsThroughTheActivePhysicalSession() async throws {
        let adb = try makeStubAdb(arms: "")
        let environment = AppEnvironment.testing(adb: adb.client)
        let pasteboard = try XCTUnwrap(environment.pasteboard as? TestPasteboard)
        let model = AppModel(environment: environment)
        let device = AndroidDevice.online(Self.serial, model: "Pixel 8")
        let phone = FakePhysicalSession(serial: Self.serial)
        model.workspace.mirror.sessionFactoryOverride = { _, _ in phone }
        model.inventory.applyWatcherSnapshot([device], degraded: false)
        await model.mirror(device: device)
        XCTAssertTrue(model.workspace.mirror.activePhysicalSession === phone)
        XCTAssertFalse(model.preferences.clipboardAutoSyncEnabled)

        pasteboard.text = "copied on the mac"
        await model.workspace.clipboard.send(physical: model.workspace.mirror.activePhysicalSession)
        XCTAssertEqual(
            phone.clipboardWrites,
            [FakePhysicalSession.ClipboardWrite(text: "copied on the mac", paste: false)]
        )
        XCTAssertEqual(model.workspace.status.statusMessage, "Clipboard sent to the device")

        model.workspace.clipboard.receive("copied on the phone", serial: Self.serial)
        XCTAssertEqual(pasteboard.text, "copied on the mac", "auto-sync is off")
        await model.workspace.clipboard.pull(physical: model.workspace.mirror.activePhysicalSession)
        XCTAssertEqual(pasteboard.text, "copied on the phone")
        XCTAssertNil(model.workspace.status.errorMessage)

        await model.workspace.mirror.goBack()
        XCTAssertEqual(phone.backPresses, 1)
        XCTAssertTrue(adb.calls(containing: "keyevent").isEmpty, "no adb key event: \(adb.calls)")
        model.stopMirror()
    }
}
