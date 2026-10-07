import AppKit
import SwiftUI
import DeviceHubProKit

/// The sidebar row's inline name editor, Device Hub's (measured 2026-09-29
/// on DH 27.0): Rename… turns the row's title into a white field with the
/// whole name selected, the row staying in its selected colour. Return
/// commits, Esc cancels, and clicking elsewhere commits (as an `NSTableView`
/// cell editor does). A name that cannot be applied (`commit` answers false)
/// keeps editing on Return and cancels on a click elsewhere.
///
/// An AppKit field, not a SwiftUI `TextField`: the select-all on focus, the
/// Esc and the end-of-editing reasons are not reachable from SwiftUI's.
struct SidebarInlineRenameField: NSViewRepresentable {
    @Binding var text: String
    /// Whether the draft can be applied; an invalid draft is drawn red.
    let isValid: Bool
    /// Applies the draft. True: editing is over (the caller has cleared the
    /// rename state). False: the draft is refused and editing goes on.
    let commit: () -> Bool
    /// Abandons the edit (the caller clears the rename state).
    let cancel: () -> Void

    /// DH's field text is black at 70 % (its darkest ink measures #4c4c4c on
    /// the white field, 2026-09-29).
    static let textColor = NSColor(white: 0, alpha: 0.7)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = RenameTextField(string: text)
        field.delegate = context.coordinator
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = .white
        // The field is white in both appearances (Device Hub's): its editor
        // must draw light-mode ink too, or in dark mode the caret and the
        // selection are drawn white on white.
        field.appearance = NSAppearance(named: .aqua)
        field.setAccessibilityLabel("Name")
        field.focusRingType = .none
        field.font = .systemFont(ofSize: ParityMetrics.sidebarTitleFontSize, weight: .semibold)
        field.textColor = Self.textColor
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The focus and the selection are taken once the field is in its
        // window (`RenameTextField.viewDidMoveToWindow`).
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text, field.currentEditor() == nil {
            field.stringValue = text
        }
        field.textColor = isValid ? Self.textColor : .systemRed
    }

    /// The name field: takes the keyboard focus with the whole name selected
    /// as soon as it is in a window, and ends the edit (as a commit, like an
    /// `NSTableView` cell editor) on a mouse press anywhere else in the window.
    ///
    /// The focus is asked for again a few turns later when it did not stick:
    /// SwiftUI re-applies the sidebar list's own focus state after the row is
    /// rebuilt (a rename begun from the row's context menu or from File ▸
    /// Rename… found the field first responder-less, typing going nowhere).
    final class RenameTextField: NSTextField {
        private var pressMonitor: Any?
        /// Set once the edit is decided, so a late retry does not reopen it.
        var hasEnded = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removePressMonitor()
            guard window != nil else { return }
            for delay in [0.0, 0.05, 0.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.takeFocus()
                }
            }
            pressMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.currentEditor() != nil else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(point) {
                    // Resigning ends the edit: `controlTextDidEndEditing`.
                    window.makeFirstResponder(nil)
                }
                return event
            }
        }

        private func removePressMonitor() {
            if let pressMonitor { NSEvent.removeMonitor(pressMonitor) }
            pressMonitor = nil
        }

        private func takeFocus() {
            guard let window, currentEditor() == nil, !hasEnded else { return }
            window.makeFirstResponder(self)
            currentEditor()?.selectAll(nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SidebarInlineRenameField
        /// Set once Return or Esc decided the edit, so the end-of-editing
        /// notification that follows does not decide it again.
        private var finished = false

        init(_ parent: SidebarInlineRenameField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                // Sync first: the last keystroke's change may not have
                // reached the binding.
                parent.text = textView.string
                if parent.commit() {
                    finished = true
                    (control as? RenameTextField)?.hasEnded = true
                } else {
                    NSSound.beep()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finished = true
                (control as? RenameTextField)?.hasEnded = true
                parent.cancel()
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !finished else { return }
            finished = true
            (notification.object as? RenameTextField)?.hasEnded = true
            if let field = notification.object as? NSTextField {
                parent.text = field.stringValue
            }
            if !parent.commit() {
                parent.cancel()
            }
        }
    }
}

/// What a finished inline rename does with its draft; pure, so the rules are
/// testable without a row.
enum SidebarRenameOutcome: Equatable {
    /// The name is unchanged: the edit just ends.
    case unchanged
    /// Rename to this name, and end the edit.
    case apply(String)
    /// The draft cannot be applied (invalid, taken or empty): editing goes on
    /// (a click elsewhere abandons it).
    case refused

    /// An AVD's rename: `AvdNameValidation` (illegal characters, a name
    /// another AVD uses ignoring case; a case-only rename of itself is fine).
    static func avd(draft: String, current: String, existing: [String]) -> SidebarRenameOutcome {
        if draft == current { return .unchanged }
        let validation = AvdNameValidation.validate(draft, existing: existing, ignoring: current)
        return validation.isValid ? .apply(draft) : .refused
    }

    /// A simulator's rename: any non-empty name (simctl allows duplicates,
    /// as Device Hub does), trimmed.
    static func simulator(draft: String, current: String) -> SidebarRenameOutcome {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == current { return .unchanged }
        return name.isEmpty ? .refused : .apply(name)
    }
}
