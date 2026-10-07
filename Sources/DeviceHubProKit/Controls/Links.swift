import Foundation

// MARK: - Request

/// Why a link cannot be sent as typed, or why Android refused an App Links
/// command.
public enum LinkError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty
    /// No RFC 3986 scheme before the first `:` (`example.com`).
    case noScheme
    /// A C0 or C1 control character, DEL, or the invisible line and
    /// paragraph separators U+2028 and U+2029: a paste accident almost
    /// always (percent-encode it to send it).
    case controlCharacter
    /// The shell word is longer than adb carries on this device
    /// (`LinkRequest.maximumShellWordBytes`).
    case tooLong(bytes: Int, limit: Int)
    case invalidPackage(String)
    /// `cmd package get-app-links` / `verify-app-links` refused, with its
    /// output.
    case refused(String)

    public var description: String {
        switch self {
        case .empty: return "The link is empty"
        case .noScheme: return "The link has no scheme"
        case .controlCharacter: return "The link contains a control character"
        case .tooLong(let bytes, let limit): return "The link takes \(bytes) bytes after escaping; adb carries \(limit)"
        case .invalidPackage(let package): return "\"\(package)\" is not a package name"
        case .refused(let output): return output
        }
    }
}

/// One link to open as an `ACTION_VIEW` intent: the URI exactly as typed
/// (without surrounding whitespace), whether the intent carries
/// `CATEGORY_BROWSABLE`, and the app it is limited to (`-p`), if any.
///
/// Equality and hashing compare the URI's UTF-8 bytes, not Swift's
/// canonical equivalence: `é` precomposed and `e` + U+0301 reach the device
/// as different bytes, so they are different requests.
public struct LinkRequest: Sendable, Hashable {
    public let uri: String
    public let browsable: Bool
    /// nil = Automatic: Android chooses.
    public let package: String?

    /// Validates `text` for a device of `apiLevel` (nil: unknown, which
    /// takes the smaller length limit).
    public init(_ text: String, browsable: Bool = true, package: String? = nil, apiLevel: Int?) throws(LinkError) {
        let uri = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uri.isEmpty else { throw .empty }
        guard Self.schemeEnd(of: uri) != nil else { throw .noScheme }
        guard !uri.unicodeScalars.contains(where: Self.isControl) else { throw .controlCharacter }
        let bytes = AdbClient.shellWord(uri).utf8.count
        let limit = Self.maximumShellWordBytes(apiLevel: apiLevel)
        guard bytes <= limit else { throw .tooLong(bytes: bytes, limit: limit) }
        if let package {
            try AdbClient.validateLinkPackage(package)
        }
        self.uri = uri
        self.browsable = browsable
        self.package = package
    }

    /// C0, DEL, C1 (U+0085 NEXT LINE among them), U+2028 and U+2029.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00..<0x20, 0x7F...0x9F, 0x2028, 0x2029: return true
        default: return false
        }
    }

    public static func == (lhs: LinkRequest, rhs: LinkRequest) -> Bool {
        lhs.browsable == rhs.browsable && lhs.package == rhs.package && lhs.uri.utf8.elementsEqual(rhs.uri.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(browsable)
        hasher.combine(package)
        hasher.combine(uri.utf8.count)
        for byte in uri.utf8 { hasher.combine(byte) }
    }

    /// The longest shell word (`AdbClient.shellWord`) a link may take.
    ///
    /// Before API 24 (and while the level is unknown) adb has no shell
    /// protocol and the client refuses a service string over 4,096 bytes
    /// ("error: shell command too long", commandline.cpp android-16.0.0_r1:
    /// 628–633; MAX_PAYLOAD_V1 = 4 KiB): the open script adds about 380
    /// bytes around the word. From API 24 the binding limit is the host's
    /// 4-hex-digit request length, 65,535 (sockets.cpp:804), and the preview
    /// script carries the word twice (2 × 30,000 + ≈ 700). Measured on API
    /// 37: 65,023 characters went through, 70,000 gave "error: closed".
    public static func maximumShellWordBytes(apiLevel: Int?) -> Int {
        if let apiLevel, apiLevel >= 24 { return 30_000 }
        return 3_700
    }

    // MARK: Parts

    /// The RFC 3986 scheme: the text before the first `:`, when it is
    /// `ALPHA *(ALPHA / DIGIT / "+" / "-" / ".")`.
    public var scheme: String? {
        Self.schemeEnd(of: uri).map { LinkUri.text(uri, uri.startIndex..<$0) }
    }

    /// The host of a hierarchical `scheme://[userinfo@]host[:port]…` link,
    /// found and decoded the way `Uri.getHost()` does on API 29+ (the
    /// authority ends at `/`, `\`, `?` or `#`; the host follows the last
    /// `@` and ends before a trailing `:digits` port; IPv6 brackets kept;
    /// `LinkUri`). nil for an opaque link (`geo:41,29`).
    public var host: String? {
        LinkUri.host(of: uri)
    }

    /// `http` or `https`, exactly: `Intent.isWebIntent` compares the scheme
    /// case-sensitively, like the intent filters do.
    public var isWebLink: Bool { scheme == "http" || scheme == "https" }

    /// Intent filters match the scheme case-sensitively: `HTTPS://` resolves
    /// nothing.
    public var schemeHasUppercase: Bool {
        scheme?.contains(where: \.isUppercase) == true
    }

    /// An http(s) link (in any case) whose decoded host (what App Links
    /// compares) has an uppercase letter: filters match the host ignoring
    /// case, App Links approval does not. `www%2Evideo.example.com` has none.
    public var webHostHasUppercase: Bool {
        guard isWebScheme else { return false }
        return host?.contains(where: \.isUppercase) == true
    }

    /// The link with its scheme lowercased, and for http and https its host
    /// too — the host's literal characters only, so `%2E` stays `%2E`; nil
    /// when that changes nothing.
    public var lowercasedForm: String? {
        guard let schemeEnd = Self.schemeEnd(of: uri) else { return nil }
        let scalars = uri.unicodeScalars
        var form = LinkUri.text(uri, scalars.startIndex..<schemeEnd).lowercased()
        if isWebScheme, let hostRange = LinkUri.encodedHostRange(of: uri) {
            form += LinkUri.text(uri, schemeEnd..<hostRange.lowerBound)
            form += Self.lowercasingLiterals(LinkUri.text(uri, hostRange))
            form += LinkUri.text(uri, hostRange.upperBound..<scalars.endIndex)
        } else {
            form += LinkUri.text(uri, schemeEnd..<scalars.endIndex)
        }
        return form.utf8.elementsEqual(uri.utf8) ? nil : form
    }

    /// `text` lowercased except its `%XX` escapes.
    private static func lowercasingLiterals(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = ""
        var index = 0
        while index < scalars.count {
            if scalars[index] == "%", index + 2 < scalars.count,
               scalars[index + 1].properties.isASCIIHexDigit, scalars[index + 2].properties.isASCIIHexDigit {
                result.unicodeScalars.append(contentsOf: scalars[index...(index + 2)])
                index += 3
            } else {
                result += String(scalars[index]).lowercased()
                index += 1
            }
        }
        return result
    }

    private var isWebScheme: Bool {
        let lowered = scheme?.lowercased()
        return lowered == "http" || lowered == "https"
    }

    /// The index of the `:` ending a valid scheme.
    private static func schemeEnd(of text: String) -> String.Index? {
        let scalars = text.unicodeScalars
        guard let colon = scalars.firstIndex(of: ":"), colon > scalars.startIndex else { return nil }
        let scheme = scalars[..<colon]
        guard let first = scheme.first, first.isASCII, first.properties.isAlphabetic else { return nil }
        let valid = scheme.allSatisfy { scalar in
            guard scalar.isASCII else { return false }
            return scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
                || scalar == "+" || scalar == "-" || scalar == "."
        }
        return valid ? colon : nil
    }
}

// MARK: - Commands

/// The Links rows' device scripts. Each is one `adb shell` round trip whose
/// status travels in the output (`@@devicehubpro:link:exit=`), never in adb's
/// exit code. After `am start`, a non-zero status always means an error or
/// an exception (API 24+); zero means none only from API 35 (and later API
/// 34 builds): earlier releases print `Error: … unable to resolve …` and
/// exit 0 (ActivityManagerShellCommand android-14.0.0_r1:760–764 `break`,
/// android-14.0.0_r50:778 `return 1`; Am.java android-7.0.0_r1:671–675 for
/// API 24–25). Before API 24 the status is not relied on.
public enum LinkCommands {
    public static let marker = "@@devicehubpro:link:"
    public static let exitMarker = marker + "exit="
    static let viewAction = "android.intent.action.VIEW"
    static let browsableCategory = "android.intent.category.BROWSABLE"
    static let defaultCategory = "android.intent.category.DEFAULT"
    /// The first API level whose `cmd package` resolves intents
    /// (PackageManagerShellCommand android-7.0.0_r1); `pm` forwards them
    /// only from API 28 (Pm.java android-7.0.0_r1 has no resolve-activity).
    public static let previewMinimumAPI = 24
    /// The first API level whose `cmd package` takes `--query-flags`
    /// (PackageManagerShellCommand android-10.0.0_r1:890–891).
    public static let queryFlagsMinimumAPI = 29
    /// `PackageManager.MATCH_ALL`: the query lists every browser, not only
    /// the default one.
    static let matchAll = "0x20000"

    enum Section: String, CaseIterable {
        case api
        case resolve
        case candidates

        var marker: String { LinkCommands.marker + rawValue }
    }

    /// `-a VIEW -d <word>[ -c BROWSABLE][ -c DEFAULT][ -p <package>]`.
    static func intentArguments(_ request: LinkRequest, addDefault: Bool, package: String?) -> String {
        var arguments = ["-a", viewAction, "-d", AdbClient.shellWord(request.uri)]
        if request.browsable { arguments += ["-c", browsableCategory] }
        if addDefault { arguments += ["-c", defaultCategory] }
        if let package { arguments += ["-p", AdbClient.shellQuoted(package)] }
        return arguments.joined(separator: " ")
    }

    /// `am start -W` (not `cmd activity`: `am` exists on every API level)
    /// with the request's intent; `-W` waits for the launch and reports it.
    public static func openScript(_ request: LinkRequest) -> String {
        "am start -W " + intentArguments(request, addDefault: false, package: request.package)
            + " 2>&1; echo \(exitMarker)$?"
    }

    /// The API level, then — from API 24 — the activity `am start` would
    /// pick and the activities that can take the link.
    ///
    /// `am start` resolves with MATCH_DEFAULT_ONLY (ActivityTaskSupervisor.
    /// resolveIntent android-16.0.0_r1:764–769); the resolve half adds
    /// `-c DEFAULT` instead, which gives the same candidates and the same
    /// App Links filtering (DomainVerificationUtils.isDomainVerificationIntent
    /// android-16.0.0_r1:54–91). Its `-p` is the Open in target, so it also
    /// says whether that app has an activity for the link.
    ///
    /// The candidates half has neither DEFAULT nor `-p`, so App Links does
    /// not filter it, and from API 29 it passes MATCH_ALL (`$flags`, split
    /// into two words) so it lists every browser: without it Android keeps
    /// only the default one (CrossProfileIntentResolverEngine
    /// android-16.0.0_r1:579–620). API 24–28 list only the default browser,
    /// and API 24–30 only the apps a user set to "always" open the domain
    /// when there are any (PackageManagerService android-11.0.0_r1:
    /// 7711–7780); so Open in's "no match" comes from the resolve half, not
    /// from this list. `LinkPreview.parse` keeps the `isDefault=false`
    /// entries apart: am never reaches them.
    public static func previewScript(_ request: LinkRequest) -> String {
        func mark(_ section: Section) -> String { "echo \(section.marker)" }
        let resolve = "cmd package resolve-activity --brief "
            + intentArguments(request, addDefault: true, package: request.package)
        let query = "cmd package query-activities --brief $flags "
            + intentArguments(request, addDefault: false, package: nil)
        return [
            mark(.api), "api=$(getprop ro.build.version.sdk)", "echo $api",
            mark(.resolve),
            "if [ \"$api\" -ge \(previewMinimumAPI) ]; then \(resolve) 2>&1; fi",
            mark(.candidates),
            "flags=",
            "if [ \"$api\" -ge \(queryFlagsMinimumAPI) ]; then flags='--query-flags \(matchAll)'; fi",
            "if [ \"$api\" -ge \(previewMinimumAPI) ]; then \(query) 2>&1; fi",
            "true",
        ].joined(separator: "; ")
    }

    /// The output's lines, split at LF, CR LF and CR only: the device
    /// prints a link's decoded host back (`am`'s `Intent { … }`), and a
    /// U+2028 or NEL there must not start a line of its own.
    public static func lines(_ output: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in output.unicodeScalars {
            if scalar == "\n" {
                if !previousWasCR { lines.append(String(current)) }
                current = String.UnicodeScalarView()
                previousWasCR = false
            } else if scalar == "\r" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
                previousWasCR = true
            } else {
                current.append(scalar)
                previousWasCR = false
            }
        }
        lines.append(String(current))
        return lines
    }

    /// The status the script's last marker line reports.
    static func exitCode(in output: String) -> Int? {
        var code: Int?
        for rawLine in lines(output) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(exitMarker) {
                code = Int(line.dropFirst(exitMarker.count))
            }
        }
        return code
    }

    /// The output without the marker lines, trimmed.
    static func withoutMarkers(_ output: String) -> String {
        lines(output)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(marker) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Components

/// An activity as `am` and `cmd package` print it (`ComponentName.
/// flattenToShortString`: `com.example.video/.UrlActivity`).
public struct LinkComponent: Sendable, Hashable, CustomStringConvertible {
    public let package: String
    /// The class as printed: `.UrlActivity` or fully qualified.
    public let className: String

    public init?(flattened: String) {
        let text = flattened.trimmingCharacters(in: .whitespaces)
        guard let slash = text.firstIndex(of: "/"), slash > text.startIndex else { return nil }
        let package = String(text[..<slash])
        let className = String(text[text.index(after: slash)...])
        guard !className.isEmpty, !package.contains(" "), !className.contains(" ") else { return nil }
        self.package = package
        self.className = className
    }

    public var flattened: String { package + "/" + className }
    public var description: String { flattened }

    /// AOSP's resolver or chooser: no app is the default for the link
    /// (`android/com.android.internal.app.ResolverActivity`, or the
    /// IntentResolver module). A build can name its own resolver
    /// (`config_customResolverActivity`, PackageManagerService
    /// android-16.0.0_r1:2217–2222, 7947–7973): the preview recognises it by
    /// its `isDefault=false` (`LinkPreview.parseResolution`), and the Open
    /// caption by the preview's resolver component.
    public var isChooser: Bool {
        if package == "com.android.intentresolver" { return true }
        return package == "android" && (className.hasSuffix("ResolverActivity") || className.hasSuffix("ChooserActivity"))
    }

    /// Another framework activity that forwards the intent (the
    /// cross-profile `IntentForwarderActivity`).
    public var isFrameworkForwarder: Bool { package == "android" && !isChooser }
}

// MARK: - Launch result

/// `WaitResult.launchStateToString` (API 29+; android-16.0.0_r1:133–145).
public enum LinkLaunchState: Sendable, Equatable {
    case cold
    case warm
    case hot
    case relaunch
    /// `UNKNOWN (0)`: nothing was launched (a reused screen).
    case unknown(Int?)

    init(_ text: String) {
        switch text {
        case "COLD": self = .cold
        case "WARM": self = .warm
        case "HOT": self = .hot
        case "RELAUNCH": self = .relaunch
        default:
            if text.hasPrefix("UNKNOWN") {
                let digits = text.filter(\.isNumber)
                self = .unknown(Int(digits))
            } else {
                self = .unknown(nil)
            }
        }
    }
}

/// What `am start -W` reported (ActivityManagerShellCommand android-16.0.0_r1:
/// 874–956; android-9.0.0_r1:552–569 for the `ThisTime:` form of API 28 and
/// older). The `Starting:` line is never read: its `dat=` is redacted by
/// `Uri.toSafeString` (`dat=geo:`).
public struct LinkLaunchResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// A `Status:` line and no warning or error: Android started an
        /// activity (or the chooser).
        case started
        /// START_DELIVERED_TO_TOP: the activity was already on top.
        case deliveredToTop
        /// START_TASK_TO_FRONT: an existing task was brought to the front.
        case broughtToFront
        /// Another `Warning:` (START_SWITCHES_CANCELED,
        /// START_RETURN_INTENT_TO_CALLER), without its prefix.
        case otherWarning(String)
        /// `Error: Activity not started, unable to resolve …`.
        case notResolved
        /// Any other error or a shell exception, with Android's reason.
        case refused(String)

        /// Printed as `Error:` or an exception.
        var isError: Bool {
            switch self {
            case .notResolved, .refused: return true
            case .started, .deliveredToTop, .broughtToFront, .otherWarning: return false
            }
        }
    }

    public var outcome: Outcome
    /// `ok` or `timeout`.
    public var status: String?
    public var launchState: LinkLaunchState?
    public var activity: LinkComponent?
    /// `ThisTime:` (API 28 and older).
    public var thisTimeMs: Int?
    /// `TotalTime:`, absent when negative (a task brought to the front).
    public var totalTimeMs: Int?
    public var waitTimeMs: Int?
    public var completed: Bool
    /// The last `@@devicehubpro:link:exit=` line (see `LinkCommands` for what
    /// it means on each release).
    public var exitCode: Int?

    public init(
        outcome: Outcome,
        status: String? = nil,
        launchState: LinkLaunchState? = nil,
        activity: LinkComponent? = nil,
        thisTimeMs: Int? = nil,
        totalTimeMs: Int? = nil,
        waitTimeMs: Int? = nil,
        completed: Bool = false,
        exitCode: Int? = nil
    ) {
        self.outcome = outcome
        self.status = status
        self.launchState = launchState
        self.activity = activity
        self.thisTimeMs = thisTimeMs
        self.totalTimeMs = totalTimeMs
        self.waitTimeMs = waitTimeMs
        self.completed = completed
        self.exitCode = exitCode
    }

    public var isChooser: Bool { activity?.isChooser == true }
    public var timedOut: Bool { status == "timeout" }

    static let deliveredToTopWarning =
        "Warning: Activity not started, intent has been delivered to currently running top-most instance."
    static let broughtToFrontWarning = "Warning: Activity not started, its current task has been brought to the front"
    static let unresolvedError = "Error: Activity not started, unable to resolve"

    /// Reads `am start -W`'s report.
    ///
    /// `am` prints the link back in `Intent { … dat=… }` (`Starting:`, the
    /// unresolved error, an exception), decoded by `Uri.toSafeString`, so a
    /// `%0A` in it is a real line break and the text after it could read as
    /// `Warning:` or `Status:` lines. With `request`, those echoes are first
    /// flattened to one line (`LinkUri.safeStringEchoes`); lines split at
    /// LF and CR only (`LinkCommands.lines`). With `apiLevel`, the exit
    /// marker cross-checks the lines: from API 24 a non-zero status admits
    /// only an error, from API 35 status 0 admits none.
    public static func parse(_ output: String, request: LinkRequest? = nil, apiLevel: Int? = nil) -> LinkLaunchResult {
        var text = output
        if let request {
            for echo in LinkUri.safeStringEchoes(of: request.uri) {
                text = text.replacingOccurrences(of: echo, with: LinkUri.flattened(echo), options: .literal)
            }
        }
        var result = LinkLaunchResult(outcome: .started)
        var outcomes: [Outcome] = []
        var sawStatus = false
        var firstUnrecognised: String?
        for rawLine in LinkCommands.lines(text) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("Starting:") else { continue }
            if line.hasPrefix(LinkCommands.exitMarker) {
                result.exitCode = Int(line.dropFirst(LinkCommands.exitMarker.count))
                continue
            }
            if let value = field("Status:", line) {
                result.status = value
                sawStatus = true
            } else if let value = field("LaunchState:", line) {
                result.launchState = LinkLaunchState(value)
            } else if let value = field("Activity:", line) {
                result.activity = LinkComponent(flattened: value)
            } else if let value = field("ThisTime:", line) {
                result.thisTimeMs = nonNegative(value)
            } else if let value = field("TotalTime:", line) {
                result.totalTimeMs = nonNegative(value)
            } else if let value = field("WaitTime:", line) {
                result.waitTimeMs = nonNegative(value)
            } else if line == "Complete" {
                result.completed = true
            } else if let outcome = outcome(of: line, output: text) {
                outcomes.append(outcome)
            } else if firstUnrecognised == nil {
                firstUnrecognised = line
            }
        }
        let level = apiLevel ?? 0
        if let code = result.exitCode, code != 0, level >= LinkCommands.previewMinimumAPI {
            result.outcome = outcomes.first(where: \.isError)
                ?? .refused("am exited with status \(code)" + (firstUnrecognised.map { ": \($0)" } ?? ""))
            return result
        }
        let admitsErrors = !(result.exitCode == 0 && level >= Self.errorStatusMinimumAPI)
        if let decided = outcomes.first(where: { admitsErrors || !$0.isError }) {
            result.outcome = decided
        } else if sawStatus {
            result.outcome = .started
        } else if let error = outcomes.first {
            // Status 0 and nothing but an error: nothing contradicts it.
            result.outcome = error
        } else if let firstUnrecognised {
            result.outcome = .refused("am printed nothing Device Hub Pro recognises: \(firstUnrecognised)")
        } else {
            result.outcome = .refused("am printed nothing")
        }
        return result
    }

    /// From this API level `am start` exits 1 after every error, so status
    /// 0 means none.
    static let errorStatusMinimumAPI = 35

    /// The outcome a warning, error or exception line decides.
    private static func outcome(of line: String, output: String) -> Outcome? {
        if line.hasPrefix(deliveredToTopWarning) { return .deliveredToTop }
        if line.hasPrefix(broughtToFrontWarning) { return .broughtToFront }
        if line.hasPrefix("Warning:") {
            return .otherWarning(line.dropFirst("Warning:".count).trimmingCharacters(in: .whitespaces))
        }
        if line.hasPrefix(unresolvedError) { return .notResolved }
        // `Security exception:` (API ≤ 29, ShellCommand android-10.0.0_r1:
        // 108) and `Exception occurred while executing` (API ≤ 29 without
        // the command; API 30+ `… executing 'start':`, BasicShellCommand-
        // Handler android-11.0.0_r1:107).
        if line.hasPrefix("Error:") || line.hasPrefix("Security exception:")
            || line.hasPrefix("Exception occurred while executing") {
            return .refused(AppConditionsError.reason(fromOutput: output) ?? line)
        }
        return nil
    }

    private static func field(_ name: String, _ line: String) -> String? {
        guard line.hasPrefix(name) else { return nil }
        return line.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
    }

    private static func nonNegative(_ text: String) -> Int? {
        Int(text).flatMap { $0 >= 0 ? $0 : nil }
    }
}

// MARK: - Preview

/// One activity that can take the link, with its `ResolveInfo.match`.
public struct LinkCandidate: Sendable, Hashable {
    public let component: LinkComponent
    public let match: Int

    public init(component: LinkComponent, match: Int) {
        self.component = component
        self.match = match
    }

    /// `IntentFilter.MATCH_CATEGORY_MASK` and `MATCH_CATEGORY_HOST`
    /// (android-16.0.0_r1:231–279).
    static let matchCategoryMask = 0xfff0000
    static let matchCategoryHost = 0x0300000

    /// Whether the matching filter names the link's host (or port or
    /// path): its match category is at least MATCH_CATEGORY_HOST. A browser
    /// matches by scheme alone (`0x208000`); the video app's filter names the host
    /// and path (`0x508000`).
    public var claimsHost: Bool { (match & Self.matchCategoryMask) >= Self.matchCategoryHost }
}

/// The preview script's answer (`LinkCommands.previewScript`).
public struct LinkPreview: Sendable, Equatable {
    public enum Resolution: Sendable, Equatable {
        /// Below API 24: `cmd package` cannot resolve.
        case unavailable
        /// `No activity found`.
        case none
        /// Android would ask: no app is the default. The resolver's
        /// component (AOSP's ResolverActivity, or a build's own).
        case chooser(LinkComponent)
        case activity(LinkCandidate)
        case unreadable(String)
    }

    public var apiLevel: Int?
    public var resolution: Resolution
    /// The activities `am start` can reach (`isDefault=true`), in the
    /// query's order.
    public var candidates: [LinkCandidate]
    /// Activities whose filter matches the link but lacks CATEGORY_DEFAULT
    /// (`isDefault=false`): listed by the query, never reached by
    /// `am start` or another app's `startActivity` (MATCH_DEFAULT_ONLY).
    public var unreachable: [LinkCandidate]

    public init(
        apiLevel: Int?,
        resolution: Resolution,
        candidates: [LinkCandidate] = [],
        unreachable: [LinkCandidate] = []
    ) {
        self.apiLevel = apiLevel
        self.resolution = resolution
        self.candidates = candidates
        self.unreachable = unreachable
    }

    /// The candidates' packages, once each in order, without the framework
    /// (`android`: the chooser and the cross-profile forwarder), for Open
    /// in.
    public var packages: [String] {
        var seen = Set<String>()
        return candidates.map(\.component.package).filter { $0 != "android" && seen.insert($0).inserted }
    }

    /// The package the link would open in, when it resolves to one.
    public var resolvedPackage: String? {
        if case .activity(let candidate) = resolution { return candidate.component.package }
        return nil
    }

    /// The resolver the link resolved to, when Android would ask.
    public var resolverComponent: LinkComponent? {
        if case .chooser(let component) = resolution { return component }
        return nil
    }

    public static func parse(_ output: String) -> LinkPreview {
        let sections = ConditionsText.sections(
            from: output,
            markers: LinkCommands.Section.allCases.map { ($0, $0.marker) }
        )
        let apiText = sections[.api] ?? ""
        guard let apiLevel = Int(apiText) else {
            return LinkPreview(apiLevel: nil, resolution: .unreadable(apiText.isEmpty ? "no API level" : apiText))
        }
        guard apiLevel >= LinkCommands.previewMinimumAPI else {
            return LinkPreview(apiLevel: apiLevel, resolution: .unavailable)
        }
        let (candidates, unreachable) = parseCandidates(sections[.candidates] ?? "")
        return LinkPreview(
            apiLevel: apiLevel,
            resolution: parseResolution(sections[.resolve] ?? ""),
            candidates: candidates,
            unreachable: unreachable
        )
    }

    /// `resolve-activity --brief`: `No activity found`, or a
    /// `priority=… match=0x… isDefault=…` line and the component.
    ///
    /// The resolve intent carries CATEGORY_DEFAULT, so a filter that
    /// matches it declares DEFAULT and prints `isDefault=true`; the
    /// resolver's own ResolveInfo prints `match=0x0 … isDefault=false`
    /// (the capture `preview-chooser`). So `isDefault=false` is the chooser
    /// whatever its package: a build's own resolver included. (The
    /// cross-profile forwarder prints `match=0x0` too, but
    /// `isDefault=true`: ComputerEngine android-16.0.0_r1:1809–1812.)
    static func parseResolution(_ text: String) -> Resolution {
        let lines = LinkCommands.lines(text)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.first == "No activity found" { return .none }
        let entries = entries(in: lines)
        guard let entry = entries.first else {
            return .unreadable(lines.first ?? "no answer")
        }
        if !entry.isDefault || entry.candidate.component.isChooser {
            return .chooser(entry.candidate.component)
        }
        return .activity(entry.candidate)
    }

    /// `query-activities --brief`: `No activities found`, or `N activities
    /// found:` and one `Activity #i:` pair per activity
    /// (PackageManagerShellCommand.printResolveInfo android-7.0.0_r1:
    /// 836–859, android-16.0.0_r1:1379–1406).
    static func parseCandidates(_ text: String) -> (candidates: [LinkCandidate], unreachable: [LinkCandidate]) {
        let lines = LinkCommands.lines(text)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var candidates: [LinkCandidate] = []
        var unreachable: [LinkCandidate] = []
        for entry in entries(in: lines) {
            if entry.isDefault {
                candidates.append(entry.candidate)
            } else {
                unreachable.append(entry.candidate)
            }
        }
        return (candidates, unreachable)
    }

    private static func entries(in lines: [String]) -> [(candidate: LinkCandidate, isDefault: Bool)] {
        var entries: [(candidate: LinkCandidate, isDefault: Bool)] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard line.hasPrefix("priority="), index < lines.count,
                  let component = LinkComponent(flattened: lines[index])
            else { continue }
            index += 1
            let match = ConditionsText.word(after: "match=0x", in: line[...]).flatMap { Int($0, radix: 16) } ?? 0
            let isDefault = ConditionsText.word(after: "isDefault=", in: line[...]) == "true"
            entries.append((LinkCandidate(component: component, match: match), isDefault))
        }
        return entries
    }
}
