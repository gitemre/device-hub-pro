import AppKit
import SwiftUI
import DeviceHubProKit

/// The error alert for a failure that has a plain sentence and raw tool
/// output behind it (the emulator's log when it exits during startup): the
/// sentence in the alert, the raw tail behind a "Show Details" disclosure.
enum ErrorDetailsAlert {
    static let accessoryWidth: CGFloat = 340
    static let detailsHeight: CGFloat = 120
    private static let headerHeight: CGFloat = 20
    /// The second button, which opens the Report a Problem sheet about this
    /// error.
    static let reportButtonTitle = "Report\u{2026}"

    /// The alert, the disclosure closed. The accessory resizes the alert when
    /// the triangle is toggled. `offersReport` adds the Report… button
    /// after OK.
    @MainActor
    static func make(message: String, details: String, offersReport: Bool = false) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Device Hub Pro"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if offersReport { alert.addButton(withTitle: reportButtonTitle) }
        let accessory = DisclosureAccessory(details: details)
        accessory.onToggle = { [weak alert] in alert?.layout() }
        alert.accessoryView = accessory
        return alert
    }

    /// The accessory view of the alert: a disclosure triangle with its
    /// title and, open, the monospaced details in a scroll view.
    @MainActor
    final class DisclosureAccessory: NSView {
        let toggle = NSButton()
        let scroll = NSScrollView()
        var onToggle: (() -> Void)?

        var isOpen: Bool { toggle.state == .on }

        init(details: String) {
            super.init(frame: NSRect(x: 0, y: 0, width: ErrorDetailsAlert.accessoryWidth, height: ErrorDetailsAlert.headerHeight))

            toggle.setButtonType(.pushOnPushOff)
            toggle.bezelStyle = .disclosure
            toggle.title = ""
            toggle.state = .off
            toggle.target = self
            toggle.action = #selector(toggled)
            addSubview(toggle)

            let label = NSTextField(labelWithString: "Show Details")
            label.font = .systemFont(ofSize: 12)
            label.tag = 1
            addSubview(label)

            let text = NSTextView()
            text.isEditable = false
            text.isSelectable = true
            text.drawsBackground = false
            text.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
            text.textColor = .secondaryLabelColor
            text.string = details
            text.textContainerInset = NSSize(width: 4, height: 4)
            text.isHorizontallyResizable = false
            text.isVerticallyResizable = true
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = true
            scroll.backgroundColor = .textBackgroundColor
            scroll.borderType = .bezelBorder
            scroll.isHidden = true
            addSubview(scroll)
            relayout()
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        @objc private func toggled() {
            scroll.isHidden = !isOpen
            (subviews.first { $0.tag == 1 } as? NSTextField)?.stringValue = isOpen ? "Hide Details" : "Show Details"
            relayout()
            onToggle?()
        }

        private func relayout() {
            let header = ErrorDetailsAlert.headerHeight
            let width = ErrorDetailsAlert.accessoryWidth
            let total = isOpen ? header + 6 + ErrorDetailsAlert.detailsHeight : header
            setFrameSize(NSSize(width: width, height: total))
            toggle.frame = NSRect(x: 0, y: total - header + 2, width: 18, height: 16)
            subviews.first { $0.tag == 1 }?.frame = NSRect(x: 20, y: total - header, width: width - 20, height: header)
            scroll.frame = NSRect(x: 0, y: 0, width: width, height: ErrorDetailsAlert.detailsHeight)
        }
    }
}

/// Presents `ErrorDetailsAlert` as a sheet of the host window while the
/// center holds details for its error; answering clears the error. With
/// `onReport` the alert also offers Report…, which hands the error to the
/// Report a Problem sheet.
struct ErrorDetailsAlertHost: ViewModifier {
    let center: StatusCenter
    var onReport: (@MainActor (ProblemReport.Subject) -> Void)?
    @State private var box = WindowCapture.Box()
    @State private var presenting = false

    func body(content: Content) -> some View {
        content
            .background(WindowCapture(box: box).frame(width: 0, height: 0))
            .onChange(of: center.errorDetails) { _, details in
                guard let details, !presenting, let message = center.errorMessage else { return }
                present(message: message, details: details)
            }
    }

    @MainActor
    private func present(message: String, details: String) {
        if let window = box.window, !window.isVisible { return }
        presenting = true
        let alert = ErrorDetailsAlert.make(
            message: UserFacingText.plain(message),
            details: details,
            offersReport: onReport != nil
        )
        let center = center
        let onReport = onReport
        let answered: (NSApplication.ModalResponse) -> Void = { response in
            presenting = false
            Self.handle(response: response, center: center, message: message, details: details, onReport: onReport)
        }
        if let window = box.window {
            alert.beginSheetModal(for: window, completionHandler: answered)
        } else {
            answered(alert.runModal())
        }
    }

    /// The alert was answered: the error is cleared whichever button was
    /// pressed, and Report… hands it on. The subject holds the raw
    /// message (the alert shows `UserFacingText.plain`) and the details by
    /// line. The hand-over waits one turn of the main actor so the alert's
    /// sheet has ended before the Report a Problem sheet appears.
    @MainActor
    static func handle(
        response: NSApplication.ModalResponse,
        center: StatusCenter,
        message: String,
        details: String,
        onReport: (@MainActor (ProblemReport.Subject) -> Void)?
    ) {
        center.errorMessage = nil
        guard response == .alertSecondButtonReturn, let onReport else { return }
        let subject = ProblemReport.Subject(
            message: message,
            details: details.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init),
            occurredAt: Date()
        )
        Task { @MainActor in onReport(subject) }
    }
}
