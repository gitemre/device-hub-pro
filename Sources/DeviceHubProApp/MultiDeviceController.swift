import Foundation
import Observation
import DeviceHubProKit

/// Apply to Selected and Screenshot All Selected (Device
/// Hub B9): one action on every device the sidebar's multi-selection holds,
/// Android and simulators mixed. The rows are resolved to targets when the
/// action runs (`BatchTargeting`), planned per device (`BatchPlanner`: a
/// device that is not ready, or whose platform cannot take the action, is
/// skipped with the reason) and run side by side, four at a time
/// (`BatchRunner`). The result is Device Hub's aggregate: one line when every
/// device took it, else an alert naming each device that failed.
///
/// One batch runs at a time; Cancel stops the work in flight (its adb or
/// simctl child is terminated) and starts no more. The device work itself is
/// `perform` (`BatchPerformer` in the app, a stand-in in tests).
@MainActor
@Observable
final class MultiDeviceController {
    /// Runs one planned operation on one device: throws `BatchSkip` when the
    /// device turns out not to take it, any other error when it failed.
    typealias Perform = @MainActor @Sendable (BatchTarget, BatchOperation, BatchRunContext) async throws -> Void

    /// A row's part in the batch in flight.
    enum RowState: Equatable, Sendable {
        /// Planned to run, not started (the four-at-a-time bound).
        case waiting
        case running
    }

    /// The action in flight; nil when none runs.
    private(set) var runningAction: BatchAction?
    /// The rows of the batch in flight that have not ended (by
    /// `BatchTarget.id`): the sidebar shows them working.
    private(set) var rowStates: [String: RowState] = [:]
    /// The status line of the batch in flight (its Cancel shows beside it).
    private(set) var progressMessage: String?
    /// What the last batch did.
    private(set) var lastReport: BatchReport?
    /// How long the last batch took, from the plan to its last device (the
    /// bound: dark mode on four mixed devices within 5 s).
    private(set) var lastElapsed: Duration?

    var isRunning: Bool { runningAction != nil }

    /// The settings a profile did not apply, by device (`BatchTarget.id`),
    /// as "Not applied on X: …" lines; reset with each batch.
    @ObservationIgnored private(set) var profileNotes: [String: [String]] = [:]

    func recordProfileNotes(_ targetID: String, _ notes: [String]) {
        profileNotes[targetID, default: []].append(contentsOf: notes)
    }

    @ObservationIgnored var perform: Perform
    @ObservationIgnored private let status: StatusCenter
    @ObservationIgnored private let picker: any FileDestinationPicker
    @ObservationIgnored private var task: Task<BatchReport, Never>?
    /// The capture folder (Settings ▸ Screenshots ▸ Save in); nil = the
    /// picker's default. Screenshot All Selected saves its folder there
    /// without asking, like a single screenshot.
    @ObservationIgnored var captureFolder: @MainActor () -> URL? = { nil }

    init(
        status: StatusCenter,
        picker: any FileDestinationPicker,
        perform: @escaping Perform = { _, _, _ in }
    ) {
        self.status = status
        self.picker = picker
        self.perform = perform
    }

    /// Runs `action` on `targets` and reports it: a flash when nothing
    /// failed, else the error alert naming each failed device. Returns the
    /// report; nil when another batch runs, or when nothing was asked.
    @discardableResult
    func run(
        _ action: BatchAction,
        on targets: [BatchTarget],
        context: BatchRunContext = BatchRunContext(),
        maxConcurrent: Int = BatchRunner.defaultConcurrency,
        excluded: [String] = []
    ) async -> BatchReport? {
        guard runningAction == nil else { return nil }
        if targets.isEmpty {
            if !excluded.isEmpty {
                status.errorMessage = Self.excludedLine(excluded, all: true)
            }
            return nil
        }
        let started = ContinuousClock.now
        profileNotes = [:]
        let steps = BatchPlanner.plan(action, for: targets)
        // A row selected twice runs once, in the selection's order.
        var order: [String] = []
        var byID: [String: BatchTarget] = [:]
        for target in targets where byID[target.id] == nil {
            byID[target.id] = target
            order.append(target.id)
        }
        let ids = order
        let targetsByID = byID
        // Only the devices the plan runs take a slot; the others are skipped
        // with their reason and never shown working.
        let runnable = ids.filter { steps[$0]?.operation != nil }
        runningAction = action
        rowStates = Dictionary(uniqueKeysWithValues: runnable.map { ($0, RowState.waiting) })
        let progress = Self.progressLine(action, count: ids.count)
        progressMessage = progress
        status.showProgress(progress)

        let perform = self.perform
        let batch = Task { () async -> BatchReport in
            var outcomes = await BatchRunner.run(
                runnable,
                maxConcurrent: maxConcurrent,
                describe: { MultiDeviceController.describe($0) },
                onStart: { id in await self.note(id, .running) },
                onFinish: { id, _ in await self.note(id, nil) }
            ) { (id: String) async throws -> Void in
                guard let target = targetsByID[id], let operation = steps[id]?.operation else {
                    throw BatchSkip("No longer listed")
                }
                // What the plan leaves out of a profile is reported here; what
                // the device turns out not to take, by the device work.
                if case .profile(let plan) = operation,
                   let line = ProfileSkip.summary(plan.skipped, on: target.name) {
                    await self.recordProfileNotes(id, [line])
                }
                try await perform(target, operation, context)
            }
            for id in ids {
                if outcomes[id] == nil, let reason = steps[id]?.skipReason {
                    outcomes[id] = .skipped(reason)
                }
            }
            let names = Self.displayNames(for: ids.compactMap { targetsByID[$0] })
            return BatchReport(ids, outcomes: outcomes) { names[$0] ?? targetsByID[$0]?.name ?? $0 }
        }
        task = batch
        var report = await batch.value
        // Rows batch actions never reach are counted, not dropped.
        report.skipped += excluded.map { BatchReport.Entry(name: $0, message: Self.excludedReason) }
        task = nil
        progressMessage = nil
        runningAction = nil
        rowStates = [:]
        lastReport = report
        lastElapsed = ContinuousClock.now - started
        status.clear(ifShowing: progress)
        // What a profile left out, in the order of the selection.
        let notes = ids.flatMap { profileNotes[$0] ?? [] }
        if let text = Self.alertText(title: action.title, report: report, notes: notes) {
            status.errorMessage = text
        } else if notes.isEmpty {
            status.flash("\(action.title): \(report.headline)")
        } else {
            status.flash("\(action.title): \(report.headline). " + notes.joined(separator: " "), seconds: 6)
        }
        return report
    }

    /// Stops the batch in flight: the devices still working end cancelled,
    /// and no more start.
    func cancel() {
        task?.cancel()
    }

    /// Screenshot All Selected: creates a folder named
    /// `BatchScreenshotNaming.folderName` in the capture folder, without
    /// asking (as a single screenshot saves), and saves one PNG per ready
    /// device in it, named after the device. With no capture folder at all
    /// it asks where the folder goes. Nil when that was cancelled or the
    /// folder could not be made.
    @discardableResult
    func screenshotAll(_ targets: [BatchTarget], at date: Date = Date(), excluded: [String] = []) async -> BatchReport? {
        guard runningAction == nil else { return nil }
        guard !targets.isEmpty else {
            if !excluded.isEmpty { status.errorMessage = Self.excludedLine(excluded, all: true) }
            return nil
        }
        let name = BatchScreenshotNaming.folderName(at: date)
        let folder: URL
        if let parent = captureFolder() ?? picker.autoSaveDirectory {
            folder = MediaCaptureController.uniqueURL(in: parent, name: name)
        } else if let chosen = picker.chooseDestination(suggestedName: name, directory: nil) {
            folder = chosen
        } else {
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            status.errorMessage = "Unable to create “\(folder.lastPathComponent)”: \(error.localizedDescription)"
            return nil
        }
        let names = BatchScreenshotNaming.fileNames(for: targets)
        let destinations = names.mapValues { folder.appendingPathComponent($0, isDirectory: false) }
        return await run(.screenshot, on: targets, context: BatchRunContext(screenshotDestinations: destinations), excluded: excluded)
    }

    // MARK: - Report text

    static let excludedReason = "Batch actions do not reach this row"

    /// "2 of the selected rows can't take batch actions: A, B".
    static func excludedLine(_ names: [String], all: Bool = false) -> String {
        let count = names.count
        let lead = all
            ? (count == 1 ? "The selected row can\u{2019}t take batch actions" : "None of the \(count) selected rows can take batch actions")
            : "\(count) of the selected rows can\u{2019}t take batch actions"
        return lead + ": " + names.joined(separator: ", ")
    }

    /// Device names for a report: a name two devices share gets its OS
    /// version, else a short id, appended.
    nonisolated static func displayNames(for targets: [BatchTarget]) -> [String: String] {
        var counts: [String: Int] = [:]
        for target in targets { counts[target.name, default: 0] += 1 }
        var result: [String: String] = [:]
        for target in targets {
            guard counts[target.name, default: 0] > 1 else {
                result[target.id] = target.name
                continue
            }
            let detail: String
            if let version = target.osVersion, !version.isEmpty {
                detail = [target.osName, version].compactMap { $0 }.joined(separator: " ")
            } else {
                let raw = target.id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? target.id
                detail = String(raw.suffix(4))
            }
            result[target.id] = "\(target.name) (\(detail))"
        }
        // Two devices still alike (same name and version): the short id.
        var seen: [String: Int] = [:]
        for value in result.values { seen[value, default: 0] += 1 }
        for target in targets where seen[result[target.id] ?? "", default: 0] > 1 {
            let raw = target.id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? target.id
            result[target.id] = "\(target.name) (\(raw.suffix(4)))"
        }
        return result
    }

    /// The alert for a batch where anything failed, was skipped or was
    /// cancelled, naming each device and why; nil when every device took
    /// it. `notes` are the profile lines for settings a device did not take.
    nonisolated static func alertText(title: String, report: BatchReport, notes: [String] = []) -> String? {
        guard !report.failed.isEmpty || !report.skipped.isEmpty || !report.cancelled.isEmpty else { return nil }
        var sections = ["\(title): \(report.headline)"]
        if let error = report.error { sections.append("\(error)") }
        if !report.skipped.isEmpty {
            let count = report.skipped.count == 1 ? "1 device" : "\(report.skipped.count) devices"
            sections.append((["Skipped \(count):"] + report.skipped.map { "\($0.name): \($0.message)" }).joined(separator: "\n"))
        }
        if !report.cancelled.isEmpty {
            sections.append((["Cancelled before it finished:"] + report.cancelled).joined(separator: "\n"))
        }
        if !notes.isEmpty { sections.append(notes.joined(separator: "\n")) }
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Progress

    private func note(_ id: String, _ state: RowState?) {
        rowStates[id] = state
    }

    /// "Dark Appearance on 4 devices…".
    static func progressLine(_ action: BatchAction, count: Int) -> String {
        "\(action.title) on \(count) \(count == 1 ? "device" : "devices")…"
    }

    /// A device's failure in the report: simctl's and devicectl's own
    /// message, else the error's description.
    nonisolated static func describe(_ error: any Error) -> String {
        switch error {
        case let failure as SimctlFailure: failure.message.isEmpty ? "\(failure)" : failure.message
        case let failure as DevicectlError: failure.message.isEmpty ? "\(failure)" : failure.message
        default: "\(error)"
        }
    }
}

/// What one batch hands every device's work besides its operation.
struct BatchRunContext: Sendable, Equatable {
    /// Screenshot All Selected: where each device's PNG goes (by
    /// `BatchTarget.id`).
    var screenshotDestinations: [String: URL] = [:]
}
