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
        let model = AppModel.testing()
        try assertAFieldTakesFocus(
            beside: DeviceControlPill().environment(model).environment(model.workspace),
            width: 320
        )
    }

    /// A foldable's pill, the real one with its width tiers (`ViewThatFits`)
    /// and the hinge slider in view all the time (it came and went with
    /// Option): the buttons, the slider and the capsules' interactive glass
    /// leave the key-view walk as it was, in the widest tier, one that
    /// drops Laptop and Tent, and the scaled one the compact window uses
    /// (`GeometryReader`, `scaleEffect`).
    func testATextFieldBesideTheFoldablePillTakesFocusInEveryWidth() throws {
        for width in [620, 450, 330, 258] as [CGFloat] {
            let model = AppModel.testing()
            try assertAFieldTakesFocus(
                beside: DeviceControlPill(fixture: .init()).environment(model).environment(model.workspace)
                    .frame(maxWidth: width, alignment: .leading),
                width: width
            )
        }
    }

    private func assertAFieldTakesFocus(beside pill: some View, width: CGFloat) throws {
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

        let host = NSHostingView(rootView: pill)
        host.frame = CGRect(x: 0, y: 0, width: width, height: 60)
        let field = NSTextField(frame: CGRect(x: 10, y: 80, width: 200, height: 22))
        let content = NSView(frame: CGRect(x: 0, y: 0, width: width, height: 120))
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
