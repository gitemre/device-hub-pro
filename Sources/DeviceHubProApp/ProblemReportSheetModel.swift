import AppKit
import Foundation
import Observation
import DeviceHubProKit

/// A request to show the Report a Problem sheet: Help ▸ Report a Problem…
/// (no subject) or the Report… button of an error alert, which carries the
/// error the user is reporting.
struct ProblemReportRequest: Identifiable, Equatable {
    let id = UUID()
    let subject: ProblemReport.Subject?
}

/// The Report a Problem sheet's state: collects the report off the main
/// actor, then offers it as text (Copy, Save…) or as a GitHub issue.
///
/// Nothing leaves the Mac from here except the URL `openIssue()` hands to the
/// browser; the user submits the form there. The collection reads the Mac and
/// asks only emulators (`ProblemReportCollector`), and the app's own snapshot
/// (`state`) is taken when the sheet opens.
@MainActor
@Observable
final class ProblemReportSheetModel {
    enum Phase: Equatable {
        case collecting
        case ready(PreparedProblemReport)
    }

    static let title = "Report a Problem"
    static let collectingText = "Checking this Mac\u{2026}"
    static let noFindingsText = "No known problem matches. Open an issue with the report so we can look into it."
    static let privacyCaption =
        "This is everything the report contains. Your user name, Mac name, serial numbers, addresses and tokens are left out."
    static let openedFilledNote = "The issue form opened in your browser with the report filled in."
    static let openedPasteNote = "The report is on the clipboard: paste it into the issue\u{2019}s Problem report field."

    private(set) var phase: Phase = .collecting
    /// What the last Open GitHub Issue did, for the sheet's footer.
    private(set) var footerNote: String?

    let subject: ProblemReport.Subject?

    @ObservationIgnored private let inputs: ProblemReportInputs
    @ObservationIgnored private let state: ProblemReportAppState
    @ObservationIgnored private let recentProblems: RecentProblemStore
    /// Who is connected now (`AppServices.recentProblemIdentifiers`), added to
    /// what the problem log kept with each error.
    @ObservationIgnored private let currentIdentifiers: RecentProblemIdentifiers
    @ObservationIgnored private let pasteboard: any MacPasteboard
    @ObservationIgnored private let picker: any FileDestinationPicker
    @ObservationIgnored private let status: StatusCenter
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var work: Task<PreparedProblemReport, Never>?

    init(
        subject: ProblemReport.Subject?,
        inputs: ProblemReportInputs,
        state: ProblemReportAppState,
        recentProblems: RecentProblemStore,
        currentIdentifiers: RecentProblemIdentifiers = RecentProblemIdentifiers(),
        pasteboard: any MacPasteboard,
        picker: any FileDestinationPicker,
        status: StatusCenter,
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.subject = subject
        self.inputs = inputs
        self.state = state
        self.recentProblems = recentProblems
        self.currentIdentifiers = currentIdentifiers
        self.pasteboard = pasteboard
        self.picker = picker
        self.status = status
        self.openURL = openURL
        self.now = now
    }

    /// The prepared report once the collection finished.
    var prepared: PreparedProblemReport? {
        if case .ready(let prepared) = phase { return prepared }
        return nil
    }

    var isReady: Bool { prepared != nil }

    // MARK: - Collecting

    /// Starts the collection off the main actor. Calling it again while it
    /// runs or after it finished does nothing.
    func start() {
        guard work == nil else { return }
        let inputs = inputs
        let state = state
        let subject = subject
        let recent = recentProblems.entries()
        let recentIdentifiers = recentProblems.identifiers().merging(currentIdentifiers)
        let started = now()
        let task = Task.detached(priority: .userInitiated) {
            await ProblemReportBuilder.prepare(
                inputs: inputs,
                appState: state,
                subject: subject,
                recentProblems: recent,
                recentIdentifiers: recentIdentifiers,
                now: started
            )
        }
        work = task
        Task { [weak self] in
            let prepared = await task.value
            guard let self, !task.isCancelled else { return }
            self.phase = .ready(prepared)
        }
    }

    /// Stops the collection (the sheet closed): the Kit's probes end their
    /// child processes.
    func cancel() {
        work?.cancel()
    }

    // MARK: - Using the report

    /// Puts the report on the pasteboard.
    func copy() {
        guard let prepared else { return }
        pasteboard.setString(prepared.markdown)
        status.flash("Problem report copied")
    }

    /// Saves the report as a text file where the user chooses (GitHub
    /// accepts a `.txt` as an attachment; `dhp-report analyze` reads any
    /// text).
    func save() {
        guard let prepared else { return }
        guard let destination = picker.chooseDestination(suggestedName: suggestedFileName(), directory: nil) else { return }
        do {
            try Data(prepared.markdown.utf8).write(to: destination, options: .atomic)
            status.flash("Problem report saved \u{2014} \(destination.lastPathComponent)")
        } catch {
            status.errorMessage = "Couldn\u{2019}t save the report: \(error.localizedDescription)"
        }
    }

    /// Copies the report, then opens GitHub's new-issue form in the browser
    /// with what fits in the link filled in. The report is on the clipboard
    /// either way, for the field that did not take it.
    func openIssue() {
        guard let prepared else { return }
        pasteboard.setString(prepared.markdown)
        let link = ProblemReportIssueLink.link(for: prepared)
        openURL(link.url)
        footerNote = link.includesReport ? Self.openedFilledNote : Self.openedPasteNote
    }

    /// `device-hub-pro-report-20261012-140312.txt`.
    func suggestedFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "device-hub-pro-report-\(formatter.string(from: now())).txt"
    }
}
