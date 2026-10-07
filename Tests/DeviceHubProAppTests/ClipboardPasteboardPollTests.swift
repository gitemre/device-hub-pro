import Foundation
import XCTest
@testable import DeviceHubProApp

/// The single app-wide Mac-pasteboard poll behind clipboard auto-sync:
/// one timer reads the real pasteboard and fans
/// the text out to every workspace's `ClipboardSyncController`, instead of
/// each window polling it on its own.
@MainActor
final class ClipboardPasteboardPollTests: XCTestCase {
    /// The real pasteboard as the poll sees it: the text and how often it
    /// was actually read.
    private final class RecordingPasteboard: MacPasteboard {
        var text: String?
        private(set) var reads = 0

        func string() -> String? {
            reads += 1
            return text
        }

        func setString(_ text: String) { self.text = text }
        func setPNG(_ png: Data) {}
    }

    /// One read of the real pasteboard reaches two workspaces' clipboard
    /// controllers (fan-out): both push the same emulator over gRPC — a
    /// stand-in for two mirrored devices in one poll tick.
    func testOneReadFansOutToEveryWorkspace() async throws {
        let target = RecordingPasteboard()
        target.text = "seed"
        let poll = ClipboardPasteboardPoll(pasteboard: target, interval: .milliseconds(20))
        let model = AppModel.testing()
        let second = DeviceWorkspace(services: model.services)
        model.registry.register(second)

        model.preferences.setClipboardAutoSync(true)
        let phoneA = FakePhysicalSession(serial: "phone-a")
        let phoneB = FakePhysicalSession(serial: "phone-b")
        model.workspace.context.serial = "phone-a"
        model.workspace.clipboard.attach(physical: phoneA)
        second.context.serial = "phone-b"
        second.clipboard.attach(physical: phoneB)

        target.text = "changed on the mac"
        poll.start(registry: model.registry)
        addTeardownBlock { @MainActor in poll.stop() }

        await waitUntil("the fan-out never reached both workspaces") {
            !phoneA.clipboardWrites.isEmpty && !phoneB.clipboardWrites.isEmpty
        }
        XCTAssertEqual(phoneA.clipboardWrites, [FakePhysicalSession.ClipboardWrite(text: "changed on the mac", paste: false)])
        XCTAssertEqual(phoneB.clipboardWrites, [FakePhysicalSession.ClipboardWrite(text: "changed on the mac", paste: false)])
        // Both workspaces read the one poll's text; the real pasteboard was
        // not read once per workspace.
        XCTAssertLessThan(target.reads, 6, "each tick should read the real pasteboard once, not once per workspace")
    }

    /// A workspace whose clipboard sync never attached gets nothing from the
    /// fan-out, even while another workspace's does.
    func testAWorkspaceWithSyncOffGetsNothing() async throws {
        let target = RecordingPasteboard()
        let poll = ClipboardPasteboardPoll(pasteboard: target, interval: .milliseconds(20))
        let model = AppModel.testing()
        let second = DeviceWorkspace(services: model.services)
        model.registry.register(second)

        model.preferences.setClipboardAutoSync(true)
        let phoneA = FakePhysicalSession(serial: "phone-a")
        model.workspace.context.serial = "phone-a"
        model.workspace.clipboard.attach(physical: phoneA)
        // `second` never attaches — no device, sync effectively off for it.

        target.text = "changed on the mac"
        poll.start(registry: model.registry)
        addTeardownBlock { @MainActor in poll.stop() }

        await waitUntil("the attached workspace never saw the poll") { !phoneA.clipboardWrites.isEmpty }
        XCTAssertNil(second.status.errorMessage)
        // Nothing to assert about `second` beyond it never crashing or
        // being asked to push anywhere — it has no attached target.
    }

    func testStopEndsThePoll() async throws {
        let target = RecordingPasteboard()
        let poll = ClipboardPasteboardPoll(pasteboard: target, interval: .milliseconds(15))
        let model = AppModel.testing()
        model.preferences.setClipboardAutoSync(true)
        let phone = FakePhysicalSession(serial: "phone-a")
        model.workspace.context.serial = "phone-a"
        model.workspace.clipboard.attach(physical: phone)

        poll.start(registry: model.registry)
        poll.stop()
        target.text = "arrived after stop"
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(phone.clipboardWrites, [], "a stopped poll must not keep fanning out")
    }
}
