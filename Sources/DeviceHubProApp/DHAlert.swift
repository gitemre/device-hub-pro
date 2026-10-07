import AppKit
import SwiftUI

/// Device Hub's confirmation alerts (measured on DH 27.0, 2026-09-29): an
/// AppKit alert sheet of the window, 260 pt wide, with curly quotes in the
/// title, the destructive answer on the right and the safe one on the left.
///
/// - Remove: no icon, a blue default "Remove", "Cancel".
/// - Reset Content and Settings: the yellow caution triangle above the
///   title, a red "Reset" and "Don't Reset".
///
/// SwiftUI's `.alert` cannot draw the caution icon, so the sheet is an
/// `NSAlert` presented on the window that hosts the modifier.
struct DHAlertSpec: Equatable {
    enum Style: Equatable {
        /// A blue default answer, no icon (Device Hub's Remove).
        case plain
        /// A red answer without an icon.
        case destructive
        /// A red answer under the yellow caution triangle (Device Hub's
        /// Reset Content and Settings).
        case caution
    }

    let title: String
    let message: String
    let confirmTitle: String
    let cancelTitle: String
    let style: Style
    /// Whether Return answers the alert. Never for any alert today: every
    /// confirmation here changes or removes something, so only a click on
    /// the answer confirms it and a stray Return does nothing.
    var confirmsOnReturn: Bool { false }

    init(
        title: String,
        message: String,
        confirmTitle: String,
        cancelTitle: String = "Cancel",
        style: Style
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
        self.style = style
    }

    /// The alert, its first button being the answer (AppKit puts it on the
    /// right and makes it the default).
    @MainActor
    func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let answer = alert.addButton(withTitle: confirmTitle)
        let cancel = alert.addButton(withTitle: cancelTitle)
        cancel.keyEquivalent = "\u{1b}"
        if !confirmsOnReturn { answer.keyEquivalent = "" }
        switch style {
        case .plain:
            break
        case .destructive:
            answer.hasDestructiveAction = true
        case .caution:
            answer.hasDestructiveAction = true
            alert.alertStyle = .critical
            alert.icon = NSImage(named: NSImage.cautionName)
        }
        return alert
    }
}

/// "Straight quotes typed by a name" are shown as Device Hub shows them.
func dhQuoted(_ name: String) -> String { "\u{201C}\(name)\u{201D}" }

/// The window a view lives in, found once the view is placed.
struct WindowCapture: NSViewRepresentable {
    final class Box {
        weak var window: NSWindow?
    }

    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = CaptureView()
        view.box = box
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CaptureView)?.box = box
        box.window = nsView.window
    }

    private final class CaptureView: NSView {
        var box: Box?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            box?.window = window
        }
    }
}

/// Presents `spec(item)` as an alert sheet while `item` is non-nil, and calls
/// `resolve(item, confirmed)` when it is answered. `item` is reset by the
/// caller's `resolve`.
private struct DHAlertModifier<Item: Equatable>: ViewModifier {
    let item: Item?
    let spec: (Item) -> DHAlertSpec
    let resolve: (Item, Bool) -> Void
    @State private var box = WindowCapture.Box()
    @State private var presented: Item?

    func body(content: Content) -> some View {
        content
            .background(WindowCapture(box: box).frame(width: 0, height: 0))
            .onChange(of: item) { _, new in
                guard let new, presented != new else {
                    if new == nil { presented = nil }
                    return
                }
                present(new)
            }
    }

    @MainActor
    private func present(_ item: Item) {
        // A window that is out of sight (the main window while the compact
        // window replaces it) leaves the question to the window on screen.
        // The caller's item is answered as cancelled so the shared item is
        // not left stuck while no sheet can show it.
        if let window = box.window, !window.isVisible {
            resolve(item, false)
            return
        }
        presented = item
        let alert = spec(item).makeAlert()
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            presented = nil
            resolve(item, response == .alertFirstButtonReturn)
        }
        if let window = box.window {
            alert.beginSheetModal(for: window, completionHandler: answer)
        } else {
            answer(alert.runModal())
        }
    }
}

extension View {
    /// An alert in Device Hub's style for a non-nil `item`.
    func dhAlert<Item: Equatable>(
        item: Item?,
        spec: @escaping (Item) -> DHAlertSpec,
        resolve: @escaping (Item, Bool) -> Void
    ) -> some View {
        modifier(DHAlertModifier(item: item, spec: spec, resolve: resolve))
    }
}
