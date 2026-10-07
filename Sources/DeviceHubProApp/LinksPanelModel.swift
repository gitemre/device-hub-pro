import Foundation
import DeviceHubProKit

/// The Links group: which rows show, the popups' options, and every text
/// the rows derive from a request, a preview, a launch report or an App
/// Links reading. Pure, so the gating and the wording are unit-tested
/// without a device.
/// The API level the URL row's preview gates on.
enum LinksAPI {
    /// Open in and the preview: `cmd package resolve-activity` (Android 7).
    static let handlerMinimum = LinkCommands.previewMinimumAPI
}

// MARK: - Popup options

/// One Recent entry. The full URI is the option's id and value; only its
/// title is shortened.
struct RecentLinkOption: Identifiable, Hashable {
    let uri: String
    var id: String { uri }
}

/// What an Open reported, or why it has no report.
enum LinkOpenOutcome: Equatable {
    case result(LinkLaunchResult)
    /// adb's bound (`seconds`) elapsed with no answer: adb may not have
    /// reached the device, or `am start -W` is still waiting for the launch.
    case noReport(seconds: Int64)
    /// adb could not reach the device.
    case failed(String)
}

enum LinksRowText {
    // MARK: Help

    static let urlHelp =
        "The URI Android receives as the intent's data (am start -a android.intent.action.VIEW -d <URI>). Sent exactly as typed, without surrounding spaces: Device Hub Pro quotes it for the device shell and escapes non-ASCII bytes so they arrive unchanged."

    // MARK: Recent

    /// The recent links' glyph: the Links row's Recent popup and the
    /// simulator's Open URL sheet.
    static let recentGlyph = "clock.arrow.circlepath"

    /// The Recent popup's title for a link: at most 60 characters, with a
    /// middle ellipsis (the popover has no line limit).
    static func recentTitle(_ uri: String) -> String {
        shortened(uri, to: 60)
    }

    static func shortened(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = (limit - 1) / 2 + (limit - 1) % 2
        let tail = limit - 1 - head
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }

    // MARK: URL

    static let emptyCaption = "Opens a web link or an app's deep link on the device as an ACTION_VIEW intent."

    static let noPreviewCaption = "Android 6 and older cannot preview the app; Open reports what handled it."

    /// The caption under URL: why the draft cannot be sent, or which app
    /// the preview says opens it. `preview` and `previewError` belong to
    /// the validated request (the controller hands over only those).
    static func urlCaption(
        validation: Result<LinkRequest, LinkError>?,
        preview: LinkPreview?,
        previewError: String?,
        apiLevel: Int?
    ) -> String {
        guard let validation else { return emptyCaption }
        let request: LinkRequest
        switch validation {
        case .failure(let error):
            return validationCaption(error)
        case .success(let valid):
            request = valid
        }
        if let apiLevel, apiLevel < LinksAPI.handlerMinimum { return noPreviewCaption }
        if let previewError { return "Could not check which app opens it: \(sentence(previewError))" }
        guard let preview else { return "Checking which app opens it…" }
        return resolutionCaption(preview, request: request, apiLevel: apiLevel)
    }

    static func validationCaption(_ error: LinkError) -> String {
        switch error {
        case .empty:
            return emptyCaption
        case .noScheme:
            return "Add a scheme: https:// for a web link, or the app's own (myapp://)."
        case .controlCharacter:
            return "The link contains a line break, tab or other control character. Percent-encode it (%0A, %09) to send it."
        case .tooLong(_, let limit):
            return "Too long for this device: Device Hub Pro sends links up to \(grouped(limit)) bytes after escaping (a non-ASCII character takes 8 to 16)."
        case .invalidPackage(let package):
            return "\(package) is not a package name."
        case .refused(let reason):
            return sentence(reason)
        }
    }

    static func resolutionCaption(_ preview: LinkPreview, request: LinkRequest, apiLevel: Int?) -> String {
        switch preview.resolution {
        case .unavailable:
            return noPreviewCaption
        case .unreadable(let text):
            return "Could not check which app opens it: \(sentence(text))"
        case .activity(let candidate):
            let component = candidate.component.flattened
            let others = preview.packages.count
            let base: String
            if others > 1 {
                base = "Opens in \(component). \(others) apps can open it."
            } else {
                base = "Opens in \(component)."
            }
            return base + hints(for: request, apiLevel: apiLevel, unresolved: false)
        case .chooser:
            var text = "Android will ask which app to open it with: no app is the default for it."
            if let scheme = request.scheme?.lowercased(), scheme == "content" || scheme == "file" {
                text += " Android also matches the provider's file type when it opens these links, so the choice can differ."
            }
            return text + hints(for: request, apiLevel: apiLevel, unresolved: false)
        case .none:
            let text: String
            if let package = request.package {
                text = "\(package) has no activity for this link"
                    + (request.browsable ? " that accepts web links (BROWSABLE)." : ".")
            } else {
                text = "No app on this device opens it" + (request.browsable ? " as a web link (Browsable)." : ".")
            }
            return text + unreachableHint(preview, request: request) + hints(for: request, apiLevel: apiLevel, unresolved: true)
        }
    }

    /// Added when nothing resolves: the activities whose filter matches the
    /// link but lacks CATEGORY_DEFAULT (`LinkPreview.unreachable`; with
    /// Open in, the target's only) — the usual deep-link mistake.
    static func unreachableHint(_ preview: LinkPreview?, request: LinkRequest?) -> String {
        guard let preview else { return "" }
        let skipped = preview.unreachable.filter { candidate in
            request?.package.map { candidate.component.package == $0 } ?? true
        }
        guard !skipped.isEmpty else { return "" }
        var names = skipped.prefix(2).map(\.component.flattened).joined(separator: ", ")
        if skipped.count > 2 { names += " and \(skipped.count - 2) more" }
        if skipped.count == 1 {
            return " \(names) matches it, but its filter lacks android.intent.category.DEFAULT, so am start and other apps' startActivity never reach it."
        }
        return " \(names) match it, but their filters lack android.intent.category.DEFAULT, so am start and other apps' startActivity never reach them."
    }

    /// Sentences appended after a resolution: the scheme's case (filters
    /// match it case-sensitively), the host's case (App Links approval
    /// compares it exactly, API 31+), and `intent:` links (a browser's
    /// syntax, not Android's).
    static func hints(for request: LinkRequest, apiLevel: Int?, unresolved: Bool) -> String {
        var text = ""
        if request.schemeHasUppercase, let scheme = request.scheme, let form = request.lowercasedForm {
            text += " Android matches the scheme case-sensitively (\(scheme) is not \(scheme.lowercased())): try \(shortened(form, to: 80))."
        }
        if unresolved, request.scheme?.lowercased() == "intent" {
            text += " intent: links are read by the web page's browser (Intent.parseUri), not by Android's VIEW resolution: open the URI it names instead."
        }
        return text
    }

    // MARK: Open

    static let openIdleCaption = "Runs am start -W with ACTION_VIEW and reports what Android started."

    static let openingCaption = "Opening: am start -W reports once the app's first screen has drawn."

    /// The caption under Open: "Opening…" while an Open runs; the last
    /// Open's report while the draft is still that request (byte equality,
    /// Browsable and Open in included); the idle caption otherwise, so a
    /// report never describes another link.
    static func openRowCaption(
        outcome: LinkOpenOutcome?,
        openedRequest: LinkRequest?,
        current: LinkRequest?,
        isOpening: Bool,
        preview: LinkPreview?,
        apiLevel: Int?
    ) -> String {
        if isOpening { return openingCaption }
        guard let outcome, let openedRequest, let current, openedRequest == current else { return openIdleCaption }
        return openCaption(outcome: outcome, request: openedRequest, preview: preview, apiLevel: apiLevel)
    }

    static func launchKind(_ state: LinkLaunchState?) -> String? {
        switch state {
        case .cold: return "cold start"
        case .warm: return "warm start"
        case .hot: return "hot start"
        case .relaunch: return "relaunched"
        case .unknown, nil: return nil
        }
    }

    /// The caption under Open: what the last Open reported. `preview` is the
    /// preview of the same request, when there is one.
    static func openCaption(
        outcome: LinkOpenOutcome?,
        request: LinkRequest?,
        preview: LinkPreview?,
        apiLevel: Int? = nil
    ) -> String {
        guard let outcome else { return openIdleCaption }
        switch outcome {
        case .noReport(let seconds):
            return "No answer within \(seconds) s: either the device could not be reached, or the app is still launching (waiting for a debugger, or stuck before its first frame). Check the device screen."
        case .failed(let message):
            return "No answer from the device: \(sentence(message))"
        case .result(let result):
            return resultCaption(result, request: request, preview: preview, apiLevel: apiLevel)
        }
    }

    private static func resultCaption(
        _ result: LinkLaunchResult,
        request: LinkRequest?,
        preview: LinkPreview?,
        apiLevel: Int?
    ) -> String {
        switch result.outcome {
        case .started:
            if result.timedOut {
                return "Android started it, but reported a timeout before the screen drew."
            }
            // A build's own resolver has another name: the preview of the
            // same request names it.
            if result.isChooser || (result.activity != nil && result.activity == preview?.resolverComponent) {
                return "Android asked which app to open it with; the choice is on the device screen."
            }
            guard let activity = result.activity else {
                return "Android started it without naming the activity."
            }
            let details = ([activity.flattened, launchKind(result.launchState)]
                + [result.totalTimeMs.map { "\($0) ms" }]).compactMap { $0 }.joined(separator: " · ")
            if let expected = preview?.resolvedPackage, expected != activity.package {
                return "Sent to \(expected); the screen now shows \(details)."
            }
            return "Opened \(details)."
        case .deliveredToTop:
            let activity = result.activity?.flattened ?? "the app's screen"
            return "Android started no new screen: \(activity) was already on top. If it is singleTop or singleTask it received the link in onNewIntent; otherwise Android only reused the screen and the app did not get this link."
        case .broughtToFront:
            let package = result.activity?.package ?? request?.package ?? "the app"
            return "Android brought \(package)'s existing task to the front instead of starting a screen. If the activity is singleTop or singleTask it received the link in onNewIntent; otherwise the app did not get this link. Force-stop the app (Apps ▸ Force Stop) to test a fresh start."
        case .otherWarning(let text):
            return sentence(text)
        case .notResolved:
            var text = "No app opened it: Android found no activity for this link"
            if let package = request?.package { text += " in \(package)" }
            text += request?.browsable == false ? "." : " that accepts web links."
            text += unreachableHint(preview, request: request)
            if let request { text += hints(for: request, apiLevel: apiLevel, unresolved: true) }
            return text
        case .refused(let reason):
            return "Android refused to open it: \(sentence(reason))"
        }
    }

    // MARK: Pieces

    /// `text` as a sentence: trimmed, with one closing full stop.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return ".!?…".contains(last) ? trimmed : trimmed + "."
    }

    /// `30,000`, whatever the Mac's locale (the captions are English).
    static func grouped(_ value: Int) -> String {
        let digits = String(value)
        var result = ""
        for (index, character) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return result
    }
}
