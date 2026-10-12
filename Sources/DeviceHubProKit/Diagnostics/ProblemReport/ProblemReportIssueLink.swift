import Foundation

/// The link that opens a new GitHub issue from the bug report form with the
/// fields a report can fill. Nothing is sent from the Mac: the app opens this
/// URL in the browser, and the user submits the form.
public enum ProblemReportIssueLink {
    public static let repository = "gitemre/device-hub-pro"
    public static let template = "bug_report.yml"
    /// The id of the form's problem report field.
    public static let reportFieldID = "report"
    /// The longest URL the link may be (browsers and GitHub refuse far longer
    /// ones).
    public static let maxURLLength = 6_000
    public static let clipboardNote = "The report is on the clipboard: select this line and paste (\u{2318}V)."

    public struct Link: Sendable, Equatable {
        public let url: URL
        /// Whether the report is in the URL; otherwise the field holds
        /// `clipboardNote` and the report is on the clipboard.
        public let includesReport: Bool
    }

    /// The link for `prepared`. Every value comes from the scrubbed report.
    public static func link(for prepared: PreparedProblemReport) -> Link {
        let report = prepared.report
        var fields: [(name: String, value: String)] = [("template", template)]

        if let subject = report.subject {
            let firstLine = subject.message.split(whereSeparator: \.isNewline).first.map(String.init) ?? subject.message
            fields.append(("title", String(firstLine.prefix(80))))
            fields.append(("what", "Device Hub Pro showed: \u{201C}\(String(subject.message.prefix(300)))\u{201D}\n\n"))
        }
        fields.append(("app-version", appVersion(report)))
        fields.append(("macos", macOS(report)))
        let details = deviceDetails(report)
        if !details.isEmpty { fields.append(("device-details", details)) }
        let avdNames = report.android.avds.map(\.name) + report.android.runningEmulators.map(\.avd)
        if let subject = report.subject, avdNames.contains(where: { subject.message.contains($0) }) {
            // GitHub does not document prefilling a dropdown; an ignored
            // parameter is harmless.
            fields.append(("device", "Android emulator"))
        }

        func url(report text: String) -> URL? {
            let query = (fields + [(reportFieldID, text)])
                .map { "\($0.name)=\(percentEncoded($0.value))" }
                .joined(separator: "&")
            return URL(string: "https://github.com/\(repository)/issues/new?\(query)")
        }
        if let full = url(report: prepared.markdown), full.absoluteString.count <= maxURLLength {
            return Link(url: full, includesReport: true)
        }
        // The note alone always fits; the form without it is the fallback of a fallback.
        let url = url(report: clipboardNote)
            ?? URL(string: "https://github.com/\(repository)/issues/new?template=\(template)")!
        return Link(url: url, includesReport: false)
    }

    /// Everything but ALPHA, DIGIT and `-._~` is escaped: `+` becomes `%2B`
    /// (GitHub reads a plain `+` as a space, which `URLComponents` would leave).
    static func percentEncoded(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static func appVersion(_ report: ProblemReport) -> String {
        let app = report.app
        if app.kind == .development { return "development build" }
        guard let version = app.version else { return app.kind == .cli ? "dhp-report" : "unknown" }
        return version + (app.build.map { " (\($0))" } ?? "")
    }

    private static func macOS(_ report: ProblemReport) -> String {
        let mac = report.mac
        var text = "macOS \(mac.macOS)" + (mac.build.map { " (\($0))" } ?? "")
        if let xcode = report.apple.xcodeVersion {
            text += ", Xcode \(xcode)" + (report.apple.xcodeBuild.map { " (\($0))" } ?? "")
        } else {
            text += ", no Xcode"
        }
        return text
    }

    /// "Pixel_8_Pro (API 37.0) emulator, 2209116AG (Android 14)", at most 200
    /// characters.
    private static func deviceDetails(_ report: ProblemReport) -> String {
        var parts: [String] = []
        for emulator in report.android.runningEmulators {
            let api = report.android.avds.first { $0.name == emulator.avd }?.imageAPI
            parts.append(emulator.avd + (api.map { " (API \($0))" } ?? "") + " emulator")
        }
        for phone in report.android.phones {
            let name = phone.model ?? phone.device ?? phone.alias
            parts.append(name + (phone.androidVersion.map { " (Android \($0))" } ?? ""))
        }
        return String(parts.joined(separator: ", ").prefix(200))
    }
}
