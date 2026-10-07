import AppKit
import SwiftUI
import XCTest
@testable import DeviceHubProApp

/// A text field beside the stage pill takes focus: on macOS 27
/// a focusable view inside a `GlassEffectContainer` sent AppKit's key-view
/// walk into a loop that never ended, so focusing any text field while a
/// device was live (the sidebar's search, the log search) hung the app at
/// 100 % CPU (SIM-18). The pill now has no container.
///
/// Measured while fixing it, in this harness: the pill's old structure (its
/// three focusable buttons in a `GlassEffectContainer`, their glass joined
/// with `glassEffectUnion`) hung the test process before the field could take
/// focus, in an offscreen window, with keyboard navigation off; the pill
/// without the container returned in under two seconds.
///
/// A hang cannot be failed from the main thread it holds, so a watchdog
/// thread ends the test process with a message instead: the run fails
/// rather than waiting forever.
@MainActor
final class DeviceControlPillKeyViewTests: XCTestCase {
    func testATextFieldBesideThePillTakesFocus() throws {
        let finished = Flag()
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 20)
            guard !finished.isSet else { return }
            FileHandle.standardError.write(Data(
                "DeviceControlPillKeyViewTests: the key-view walk over the stage pill did not end (SIM-18)\n".utf8
            ))
            exit(EXIT_FAILURE)
        }
        defer { finished.set() }

        let model = AppModel.testing()
        let host = NSHostingView(rootView: DeviceControlPill().environment(model).environment(model.workspace))
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 60)
        let field = NSTextField(frame: CGRect(x: 10, y: 80, width: 200, height: 22))
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
        content.addSubview(host)
        content.addSubview(field)
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertTrue(window.makeFirstResponder(field))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        window.recalculateKeyViewLoop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the field's editor has the focus")
        XCTAssertTrue(editor.delegate === field)
        XCTAssertGreaterThan(host.fittingSize.width, 100, "the pill is laid out")
    }

    /// Set from the main thread when the test is done; read by the watchdog.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}
