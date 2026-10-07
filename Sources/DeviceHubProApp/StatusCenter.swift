import Foundation
import Observation

/// Whether a status line reports work under way or a finished action. The
/// writer states it with the line (`StatusCenter.showProgress`,
/// `showOutcome`, `flash`); the banner shows its spinner for progress only.
enum StatusBannerKind: Equatable {
    case progress
    case outcome
}

/// The window's status line, its error alert and the count of long
/// operations in flight. `AppModel` owns the app-global one as `status` and
/// each `DeviceWorkspace` its own; a call site names the one it means.
@MainActor
@Observable
final class StatusCenter {
    /// A tick shared by every `StatusCenter` (: one per
    /// workspace, plus `AppModel`'s app-global one), so `errorRevision` and
    /// `statusRevision` order writes across instances the way they ordered
    /// within the one center this app had before: whichever instance wrote
    /// most recently is the one a merged view (`active(error:_:)`,
    /// `active(status:_:)`) shows, exactly like the old shared object did.
    private static var revisionClock = 0

    var errorMessage: String? {
        didSet {
            errorDetails = nil
            bumpErrorRevision()
        }
    }
    /// The raw tool output behind `errorMessage`, shown in the alert's
    /// "Show Details" disclosure. Cleared whenever `errorMessage` is written,
    /// so set it after the message.
    var errorDetails: String?
    /// The status line; nil hides the banner. Written only together with its
    /// kind (`showProgress`, `showOutcome`, `flash`, `withElapsedStatus`).
    private(set) var statusMessage: String? {
        didSet { bumpStatusRevision() }
    }
    /// What `statusMessage` reports, stored by its writer at write time: the
    /// banner shows its spinner for `.progress` only. Never read from the
    /// text — an outcome can quote a file name or an error with an ellipsis
    /// in it. Meaningful while `statusMessage` is non-nil.
    private(set) var statusKind: StatusBannerKind = .outcome
    /// Long operations in flight (`beginBusy`/`endBusy`). A count, not a
    /// flag: two overlapping operations (two AVD starts) must not have the
    /// first to finish re-enable every busy-gated control under the second.
    private var busyOperations = 0
    /// True while any long operation runs; views gate their entry points on it.
    var isBusy: Bool { busyOperations > 0 }
    /// Bumped on every `errorMessage` write (set or cleared to nil):
    /// `active(error:_:)` picks the center with the higher value.
    private(set) var errorRevision = 0
    /// Bumped on every `statusMessage` write (a new line or a clear):
    /// `active(status:_:)` picks the center with the higher value.
    private(set) var statusRevision = 0

    private func bumpErrorRevision() {
        Self.revisionClock += 1
        errorRevision = Self.revisionClock
    }

    private func bumpStatusRevision() {
        Self.revisionClock += 1
        statusRevision = Self.revisionClock
    }

    /// Which of two centers currently owns the error alert: whichever wrote
    /// `errorMessage` (set or cleared) most recently. With one workspace
    /// this always resolves to whichever one the call site actually wrote,
    /// the same as the old shared center.
    static func active(error a: StatusCenter, _ b: StatusCenter) -> StatusCenter {
        b.errorRevision > a.errorRevision ? b : a
    }

    /// Which of two centers currently owns the status banner: whichever
    /// wrote `statusMessage` (a line or a clear) most recently.
    static func active(status a: StatusCenter, _ b: StatusCenter) -> StatusCenter {
        b.statusRevision > a.statusRevision ? b : a
    }

    /// Shows `message` as work under way (the banner's spinner) until its
    /// writer clears it.
    func showProgress(_ message: String) {
        show(message, kind: .progress)
    }

    /// Shows `message` as a finished action (no spinner) until its writer
    /// clears it; `flash` clears itself.
    func showOutcome(_ message: String) {
        show(message, kind: .outcome)
    }

    /// Clears the status line, whoever wrote it.
    func clear() {
        statusMessage = nil
    }

    /// Runs `operation` with `base` in the status line, followed by the
    /// seconds elapsed once it takes longer than a moment — for the stops,
    /// which wait for the VM to save its snapshot. Clears its own line.
    func withElapsedStatus<T>(
        _ base: String,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        showProgress(base)
        let started = ContinuousClock.now
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled,
                      self.statusMessage?.hasPrefix(base) == true
                else { return }
                let seconds = Int((ContinuousClock.now - started).components.seconds)
                self.showProgress("\(base) \(seconds) s")
            }
        }
        defer {
            ticker.cancel()
            if statusMessage?.hasPrefix(base) == true {
                statusMessage = nil
            }
        }
        return try await operation()
    }

    func beginBusy() {
        busyOperations += 1
    }

    func endBusy() {
        busyOperations = max(0, busyOperations - 1)
    }

    /// Clears the status line only while it still shows `message`: an
    /// operation ending must not wipe the line another one is using.
    func clear(ifShowing message: String?) {
        guard let message, statusMessage == message else { return }
        statusMessage = nil
    }

    /// Shows `message` as a finished action and clears it after 1.8 s, while
    /// it is still shown.
    func flash(_ message: String, seconds: Double = 1.8) {
        showOutcome(message)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if self?.statusMessage == message {
                self?.statusMessage = nil
            }
        }
    }

    private func show(_ message: String, kind: StatusBannerKind) {
        statusMessage = message
        statusKind = kind
    }
}
