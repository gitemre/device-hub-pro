import Foundation
import Observation
import DeviceHubProKit

/// The Controls panel's **URL** row (any Android device): opens a URI as an
/// `ACTION_VIEW` intent with the BROWSABLE category (the way a browser click
/// sends it, never targeting a handler) using `am start -W`, reports what
/// Android did, and previews which app will take it (API 24+).
///
/// The row writes no settings: an Open launches what the user asked for, as
/// Apps ▸ Launch does. So nothing is put back on detach, disconnect or quit;
/// `detach()` only forgets the device's readings.
///
/// Nothing polls: the URL row runs `refreshPreview` (debounced) when the
/// link, the device or its packages change, and when the row appears. Every async method captures the device, the Controls
/// generation and the request before it awaits, and applies its result only
/// while all three are still current.
///
/// One long-lived instance, owned by `AppModel` as `links` and called
/// directly by the rows (no forwarders).
@MainActor
@Observable
final class DeviceLinksController {
    let adbClient: AdbClient?
    private let context: ActiveDeviceContext
    let status: StatusCenter
    let recents: RecentLinkStore

    init(adbClient: AdbClient?, context: ActiveDeviceContext, status: StatusCenter, recents: RecentLinkStore) {
        self.adbClient = adbClient
        self.context = context
        self.status = status
        self.recents = recents
    }

    // MARK: - Draft (per Mac, kept across devices)

    var draft = ""

    // MARK: - Device readings

    private(set) var preview: LinkPreview?
    /// The request `preview` (or `previewError`) answers.
    private(set) var previewRequest: LinkRequest?
    private(set) var previewError: String?
    private(set) var isPreviewing = false
    /// The API level the preview script read, for when the Info read has
    /// none.
    private(set) var probedAPILevel: Int?

    typealias OpenOutcome = LinkOpenOutcome

    /// The last Open and what it reported.
    struct LastOpen: Equatable {
        let request: LinkRequest
        let outcome: LinkOpenOutcome
    }

    private(set) var lastOpen: LastOpen?
    private(set) var isOpening = false

    /// Bumped by `packagesChanged` and by every Open, so the preview re-runs
    /// (a build installed outside Device Hub Pro is noticed after the next Open).
    private var previewNonce = 0
    /// Bumped by `detach()`: work started before it applies nothing.
    private var epoch = 0
    /// Bumped by every `refreshPreview`: an older one applies nothing.
    private var previewSequence = 0

    // MARK: - Derived

    var showsLinks: Bool { context.serial != nil }

    func apiLevel(deviceInfo: Int?) -> Int? {
        deviceInfo ?? probedAPILevel
    }

    /// The draft as a request; nil for an empty draft.
    func validation(apiLevel: Int?) -> Result<LinkRequest, LinkError>? {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            return .success(try LinkRequest(draft, browsable: true, package: nil, apiLevel: apiLevel))
        } catch {
            return .failure(error)
        }
    }

    func request(apiLevel: Int?) -> LinkRequest? {
        if case .success(let request)? = validation(apiLevel: apiLevel) { return request }
        return nil
    }

    /// The preview when it answers `request`.
    func preview(for request: LinkRequest?) -> LinkPreview? {
        guard let request, previewRequest == request else { return nil }
        return preview
    }

    func previewError(for request: LinkRequest?) -> String? {
        guard let request, previewRequest == request else { return nil }
        return previewError
    }

    /// What re-runs the preview (`.task(id:)` on the URL row).
    struct PreviewKey: Hashable {
        let serial: String?
        let draft: [UInt8]
        let apiLevel: Int?
        let generation: UInt64
        let nonce: Int
    }

    func previewKey(apiLevel: Int?) -> PreviewKey {
        PreviewKey(
            serial: context.serial,
            draft: Array(draft.utf8),
            apiLevel: apiLevel,
            generation: context.controlsGeneration,
            nonce: previewNonce
        )
    }

    // MARK: - Preview

    /// Reads which app takes the draft and which can. No command runs for an
    /// invalid draft or on a device known to be older than API 24.
    func refreshPreview(apiLevel: Int?) async {
        previewSequence += 1
        let sequence = previewSequence
        guard let adbClient, let serial = context.serial,
              case .success(let request)? = validation(apiLevel: apiLevel)
        else {
            isPreviewing = false
            return
        }
        if let apiLevel, apiLevel < LinksAPI.handlerMinimum {
            isPreviewing = false
            return
        }
        let generation = context.controlsGeneration
        let epoch = self.epoch
        isPreviewing = true
        defer {
            if sequence == previewSequence { isPreviewing = false }
        }
        let read: Result<LinkPreview, any Error>
        do {
            read = .success(try await adbClient.linkPreview(serial: serial, request))
        } catch {
            read = .failure(error)
        }
        guard isCurrent(serial: serial, generation: generation, epoch: epoch), sequence == previewSequence,
              self.request(apiLevel: apiLevel) == request
        else { return }
        switch read {
        case .success(let result):
            preview = result
            previewError = nil
            previewRequest = request
            if let level = result.apiLevel { probedAPILevel = level }
        case .failure(let error):
            let reason = Self.shortDescription(error)
            preview = nil
            previewError = reason
            previewRequest = request
        }
    }

    // MARK: - Open

    /// Opens the draft with `am start -W`. The link joins Recents when `am`
    /// answered (a parsed report), not when adb failed or its bound elapsed
    /// with no answer (nothing says the device got the link).
    func open(apiLevel: Int?) async {
        guard let adbClient, let serial = context.serial, !isOpening,
              case .success(let request)? = validation(apiLevel: apiLevel)
        else { return }
        let generation = context.controlsGeneration
        let epoch = self.epoch
        isOpening = true
        defer { if self.epoch == epoch { isOpening = false } }
        let outcome: LinkOpenOutcome
        do {
            outcome = .result(try await adbClient.openLink(serial: serial, request, apiLevel: apiLevel))
            recents.record(request.uri)
        } catch ProcessRunnerError.timedOut(_, let seconds) {
            // No answer: adb may not have reached the device, or `am start
            // -W` (no bound of its own) is still waiting for the launch.
            outcome = .noReport(seconds: seconds.components.seconds)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(serial: serial, generation: generation, epoch: epoch) else { return }
            let reason = Self.shortDescription(error)
            lastOpen = LastOpen(request: request, outcome: .failed(reason))
            // The short reason only: adb's argv holds the whole script and
            // the link (tokens included).
            status.errorMessage = "Could not open the link on \(serial): \(reason)"
            return
        }
        guard isCurrent(serial: serial, generation: generation, epoch: epoch) else { return }
        lastOpen = LastOpen(request: request, outcome: outcome)
        previewNonce += 1
    }

    /// The caption under Open for the current draft
    /// (`LinksRowText.openRowCaption`).
    func openCaption(apiLevel: Int?) -> String {
        LinksRowText.openRowCaption(
            outcome: lastOpen?.outcome,
            openedRequest: lastOpen?.request,
            current: request(apiLevel: apiLevel),
            isOpening: isOpening,
            preview: preview(for: lastOpen?.request),
            apiLevel: apiLevel
        )
    }

    // MARK: - Recents

    func useRecent(_ uri: String) {
        draft = uri
    }

    func clearRecents() {
        recents.clear()
    }

    // MARK: - Session

    /// An install or uninstall through Device Hub Pro on the mirrored device: the
    /// preview re-runs, so a new handler (or a removed one) shows.
    func packagesChanged(serial: String) {
        guard serial == context.serial else { return }
        previewNonce += 1
    }

    /// The mirror is going away: work in flight applies nothing, and the
    /// device's readings are forgotten. The draft and Recents are the Mac's
    /// and stay.
    func detach() {
        epoch += 1
        previewSequence += 1
        preview = nil
        previewRequest = nil
        previewError = nil
        isPreviewing = false
        probedAPILevel = nil
        lastOpen = nil
        isOpening = false
    }

    private func isCurrent(serial: String, generation: UInt64, epoch: Int) -> Bool {
        !Task.isCancelled && context.serial == serial && context.controlsGeneration == generation && self.epoch == epoch
    }

    /// An error for a caption: its first line, without adb's argv.
    static func shortDescription(_ error: any Error) -> String {
        switch error {
        case AdbError.commandFailed(_, let exitCode, let message):
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "The device returned an error (status \(exitCode))" : firstLine(text)
        case ProcessRunnerError.timedOut(_, let seconds):
            return "The device did not answer within \(seconds.components.seconds) s"
        default:
            return firstLine("\(error)")
        }
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return LinksRowText.shortened(line, to: 200)
    }
}
