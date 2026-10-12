import SwiftUI
import DeviceHubProKit

/// The Report a Problem sheet (Help ▸ Report a Problem…, and the Report…
/// button of an error alert): the known causes this Mac matches, with their
/// fix, and the report itself with the private details left out, ready to
/// copy, save or open as a GitHub issue.
///
/// This view builds the model from the window's own model and workspace when
/// it appears; `ProblemReportSheetView` draws a model.
struct ProblemReportSheet: View {
    let request: ProblemReportRequest
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @State private var sheetModel: ProblemReportSheetModel?

    var body: some View {
        ProblemReportSheetView(subject: request.subject, model: sheetModel)
            .task {
                guard sheetModel == nil else { return }
                let made = ProblemReportSheetModel(
                    subject: request.subject,
                    inputs: model.problemReportInputs(),
                    state: model.problemReportState(),
                    recentProblems: model.services.environment.recentProblems,
                    currentIdentifiers: model.services.recentProblemIdentifiers(),
                    pasteboard: model.services.environment.pasteboard,
                    picker: model.services.environment.picker,
                    status: workspace.status
                )
                sheetModel = made
                made.start()
            }
            .onDisappear { sheetModel?.cancel() }
    }
}

/// The sheet's chrome and contents for `model` (nil for the instant before it
/// exists: the same sheet, collecting).
struct ProblemReportSheetView: View {
    let subject: ProblemReport.Subject?
    let model: ProblemReportSheetModel?

    static let reportHeight: CGFloat = 220
    static let findingsMaxHeight: CGFloat = 300

    var body: some View {
        let ready = model?.isReady == true
        DHSheet(
            title: ProblemReportSheetModel.title,
            width: 620,
            cancelTitle: "Close",
            actions: [
                DHSheetAction(title: "Copy", isEnabled: ready) { model?.copy() },
                DHSheetAction(title: "Save\u{2026}", isEnabled: ready) { model?.save() },
                DHSheetAction(title: "Open GitHub Issue", isEnabled: ready, isDefault: true) { model?.openIssue() },
            ],
            footerNote: model?.footerNote,
            // "Paste it into the issue's Problem report field" is the step
            // the user must not miss.
            footerNoteLines: 2
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if let subject {
                    Text("About: \u{201C}\(UserFacingText.plain(subject.message))\u{201D}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                knownProblems
                reportBox
            }
        }
    }

    // MARK: Known problems

    private var knownProblems: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Known Problems")
                .font(.subheadline.weight(.semibold))
            if let prepared = model?.prepared {
                if prepared.findings.isEmpty {
                    Text(ProblemReportSheetModel.noFindingsText)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(prepared.findings, id: \.id) { finding in
                                FindingCard(finding: finding)
                            }
                        }
                    }
                    .frame(maxHeight: Self.findingsMaxHeight)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(ProblemReportSheetModel.collectingText)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The report

    private var reportBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Report")
                .font(.subheadline.weight(.semibold))
            Text(ProblemReportSheetModel.privacyCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(verbatim: model?.prepared?.markdown ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: Self.reportHeight)
            .background(
                RoundedRectangle(cornerRadius: DHSheetMetrics.cardRadius, style: .continuous)
                    .fill(Color(nsColor: .quaternarySystemFill))
            )
        }
    }
}

/// One known cause: its title, what it is and what to do.
private struct FindingCard: View {
    let finding: ProblemFinding

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(finding.title)
                    .fontWeight(.semibold)
                if finding.confidence == .likely {
                    Text("Likely")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(finding.explanation)
                .fixedSize(horizontal: false, vertical: true)
            Text("**What to do:** \(finding.fix)")
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DHSheetMetrics.cardRadius, style: .continuous)
                .fill(Color(nsColor: .quaternarySystemFill))
        )
    }
}
