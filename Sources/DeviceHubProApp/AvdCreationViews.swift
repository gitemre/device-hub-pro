import SwiftUI
import DeviceHubProKit

extension AvdCreationJob {
    /// The row's second line: what the job is doing, with the download's
    /// percentage once sdkmanager reports one.
    func statusText(progress: Double?, licensePending: Bool) -> String {
        switch phase {
        case .waiting:
            return "Waiting for another download\u{2026}"
        case .downloading:
            if licensePending { return "Waiting for the license\u{2026}" }
            let label = "Downloading \(request.image.friendlyLabel)\u{2026}"
            guard let progress else { return label }
            return label + " \(Int((progress * 100).rounded()))%"
        case .waitingToCreate:
            return "Waiting to create\u{2026}"
        case .creating:
            return "Creating\u{2026}"
        case .failed(let message):
            return message
        }
    }
}

extension AvdCreationJob {
    /// A failed job's plain sentence and the raw text behind it; nil while
    /// the job has not failed.
    var plainFailure: PlainFailure? {
        guard case .failed(let message) = phase else { return nil }
        return PlainFailure.make(message, fallback: "Couldn\u{2019}t finish creating this emulator.")
    }
}

/// One emulator being made: its name, what it is doing, a thin progress bar
/// while downloading and Cancel (or Retry and Dismiss after a failure).
/// Shared by the sidebar and the activity popover.
struct AvdCreationRow: View {
    let job: AvdCreationJob
    let queue: AvdCreationQueue

    private var progress: Double? { queue.progress(of: job) }

    private var isFailed: Bool {
        if case .failed = job.phase { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isFailed ? "exclamationmark.triangle.fill" : "arrow.down.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isFailed ? Color.orange : Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Circle().fill((isFailed ? Color.orange : Color.accentColor).opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.request.deviceName)
                    .lineLimit(1)
                if let failure = job.plainFailure {
                    PlainFailureView(failure: failure, summaryColor: .red, font: .caption)
                } else {
                    Text(job.statusText(progress: progress, licensePending: queue.sdk.licensePrompt != nil))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
                if job.phase == .downloading {
                    if let progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trailing: some View {
        if isFailed {
            HStack(spacing: 6) {
                Button("Retry") { queue.retry(job.id) }
                    .controlSize(.small)
                Button {
                    queue.cancel(job.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        } else if job.phase != .creating {
            Button {
                queue.cancel(job.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Cancel")
            .accessibilityLabel("Cancel \(job.request.deviceName)")
        }
    }
}

/// A system image download that is not an emulator's (the "Download More
/// System Images…" sheet's), so it shows in the activity list as well.
struct DirectDownloadRow: View {
    let package: String
    let queue: AvdCreationQueue

    private var title: String {
        let parts = package.split(separator: ";").map(String.init)
        guard parts.count == 4 else { return package }
        return SystemImage(package: package, api: parts[1], tag: parts[2], abi: parts[3]).friendlyLabel
    }

    private var progress: Double? {
        if case .downloading(let progress) = queue.sdk.downloadState(package: package) { return progress }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.accentColor.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("System image")
                    .lineLimit(1)
                Text("Downloading \(title)\u{2026}" + (progress.map { " \(Int(($0 * 100).rounded()))%" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let progress {
                    ProgressView(value: progress).progressViewStyle(.linear).controlSize(.small)
                } else {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                queue.sdk.cancelDownload()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Cancel")
            .accessibilityLabel("Cancel Download")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The toolbar's activity button: shown only while something downloads or
/// is queued; opens a popover listing every job. Non-modal, so the app
/// stays usable while it is open.
struct DownloadsToolbarButton: View {
    let queue: AvdCreationQueue
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "arrow.down.circle")
                .symbolEffect(.pulse, isActive: queue.sdk.isDownloading)
        }
        .buttonStyle(.plain)
        .help("Downloads")
        .accessibilityLabel("Downloads")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            DownloadsPopover(queue: queue)
        }
    }
}

struct DownloadsPopover: View {
    let queue: AvdCreationQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Downloads")
                .font(.headline)
            if !queue.hasActivity {
                Text("Nothing is downloading.")
                    .foregroundStyle(.secondary)
            }
            if let package = queue.directDownloadPackage {
                DirectDownloadRow(package: package, queue: queue)
            }
            ForEach(queue.jobs) { job in
                AvdCreationRow(job: job, queue: queue)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
