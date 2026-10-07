import AppKit
import XCTest
@testable import DeviceHubProApp

/// The sidebar row's in-place rename (Device Hub's, measured 2026-09-29):
/// what a finished edit does with its draft.
final class SidebarInlineRenameTests: XCTestCase {
    private let existing = ["Pixel_9", "Pixel_8"]

    func testAnUnchangedAvdNameJustEndsTheEdit() {
        XCTAssertEqual(SidebarRenameOutcome.avd(draft: "Pixel_9", current: "Pixel_9", existing: existing), .unchanged)
    }

    func testAValidNewAvdNameIsApplied() {
        XCTAssertEqual(
            SidebarRenameOutcome.avd(draft: "Pixel_9_QA", current: "Pixel_9", existing: existing),
            .apply("Pixel_9_QA")
        )
    }

    /// A case-only rename of the AVD itself is allowed; another AVD's name,
    /// in any case, is not.
    func testAvdNamesAreCheckedLikeTheCreateSheet() {
        XCTAssertEqual(
            SidebarRenameOutcome.avd(draft: "pixel_9", current: "Pixel_9", existing: existing),
            .apply("pixel_9")
        )
        XCTAssertEqual(SidebarRenameOutcome.avd(draft: "pixel_8", current: "Pixel_9", existing: existing), .refused)
        XCTAssertEqual(SidebarRenameOutcome.avd(draft: "", current: "Pixel_9", existing: existing), .refused)
        XCTAssertEqual(SidebarRenameOutcome.avd(draft: "Pixel 9!", current: "Pixel_9", existing: existing), .refused)
    }

    /// A simulator takes any non-empty name (duplicates included, as in
    /// Device Hub), trimmed.
    func testASimulatorTakesAnyNonEmptyName() {
        XCTAssertEqual(SidebarRenameOutcome.simulator(draft: "QA iPhone", current: "iPhone 17"), .apply("QA iPhone"))
        XCTAssertEqual(SidebarRenameOutcome.simulator(draft: "  QA iPhone \n", current: "iPhone 17"), .apply("QA iPhone"))
        XCTAssertEqual(SidebarRenameOutcome.simulator(draft: "iPhone 17", current: "iPhone 17"), .unchanged)
        XCTAssertEqual(SidebarRenameOutcome.simulator(draft: "iPhone 17 ", current: "iPhone 17"), .unchanged)
        XCTAssertEqual(SidebarRenameOutcome.simulator(draft: "   ", current: "iPhone 17"), .refused)
    }

    /// The menu items only mark the row: Rename… (the row menu, the File
    /// menu, the toolbar) sets the target and the draft the row edits, and
    /// nothing else (no sheet is presented from these).
    @MainActor
    func testRenameRequestsMarkTheRowBeingEdited() {
        let avd = AvdActionDialogs()
        avd.requestRename("Pixel_9")
        XCTAssertEqual(avd.renameAvdName, "Pixel_9")
        XCTAssertEqual(avd.renameDraft, "Pixel_9")
    }

    /// The name field takes the keyboard focus with the whole name selected
    /// once it is in a window (a rename begun from a menu found it with
    /// neither), and a mouse press elsewhere in the window ends the edit.
    @MainActor
    func testTheNameFieldTakesFocusWithTheNameSelected() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let field = SidebarInlineRenameField.RenameTextField(string: "AQA iPhone")
        field.frame = NSRect(x: 10, y: 60, width: 200, height: 20)
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: 400_000_000)
        let editor = try XCTUnwrap(field.currentEditor(), "the field is not being edited")
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 10))
        window.orderOut(nil)
    }
}
