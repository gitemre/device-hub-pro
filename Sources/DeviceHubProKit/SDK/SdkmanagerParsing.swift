import Foundation

/// Parses `sdkmanager` output.
public enum SdkmanagerParsing {
    /// System images offered in the `Available Packages:` section of
    /// `sdkmanager --list`; installed images keep coming from the on-disk scan
    /// (`AvdmanagerClient.installedSystemImages`).
    ///
    /// Entries keep the listing's order. Rows that are not a complete
    /// `system-images;<api>;<tag>;<abi>` package are skipped.
    public static func availableImages(fromListOutput output: String) -> [SystemImage] {
        var images: [SystemImage] = []
        var inAvailablePackages = false

        for rawLine in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.caseInsensitiveCompare("Available Packages:") == .orderedSame {
                inAvailablePackages = true
                continue
            }
            guard inAvailablePackages else { continue }
            // Table rows are indented; the next section's header is not.
            if !rawLine.isEmpty, !rawLine.hasPrefix(" "), !rawLine.hasPrefix("\t") {
                break
            }
            // Old tools print a `|`-separated table of `;` paths; cmdline-tools 23
            // (the Android CLI shim) prints whitespace-separated columns of `/` paths.
            // Both are normalised to the `;` form.
            let firstCell: Substring
            if rawLine.contains("|") {
                guard let cell = rawLine.split(separator: "|", maxSplits: 1).first else { continue }
                firstCell = cell
            } else {
                guard let word = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
                    continue
                }
                firstCell = word
            }
            let package = firstCell
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "/", with: ";")
            let parts = package.split(separator: ";", omittingEmptySubsequences: false)
            guard parts.count == 4,
                  parts[0] == "system-images",
                  parts.allSatisfy({ !$0.isEmpty })
            else {
                continue
            }
            images.append(
                SystemImage(
                    package: package,
                    api: String(parts[1]),
                    tag: String(parts[2]),
                    abi: String(parts[3])
                )
            )
        }
        return images
    }

    /// The version listed for `package` (a path such as `emulator`) in the
    /// `Available Packages:` section, in the `|`-separated table of old tools
    /// or the whitespace-separated columns of cmdline-tools 23.
    public static func availableVersion(of package: String, fromListOutput output: String) -> String? {
        var inAvailablePackages = false
        for rawLine in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.caseInsensitiveCompare("Available Packages:") == .orderedSame {
                inAvailablePackages = true
                continue
            }
            guard inAvailablePackages else { continue }
            if !rawLine.isEmpty, !rawLine.hasPrefix(" "), !rawLine.hasPrefix("\t") { break }
            let cells: [String]
            if rawLine.contains("|") {
                cells = rawLine.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
                cells = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            }
            if cells.count >= 2, cells[0] == package { return cells[1] }
        }
        return nil
    }

    /// The progress a `sdkmanager` output line reports, as 0…1.
    ///
    /// A line can hold several `\r`-separated updates (the tool overwrites its
    /// progress bar); the last one wins. Returns nil when the line carries no
    /// percentage or one outside 0…100.
    public static func progress(from line: String) -> Double? {
        let segment = line
            .split(separator: "\r")
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            ?? ""
        guard let percent = segment.lastIndex(of: "%") else { return nil }

        var digits = ""
        var index = percent
        while index > segment.startIndex {
            let previous = segment.index(before: index)
            guard let value = segment[previous].wholeNumberValue, (0...9).contains(value) else {
                break
            }
            digits.insert(segment[previous], at: digits.startIndex)
            index = previous
        }
        guard digits.count <= 3, let value = Int(digits), (0...100).contains(value) else {
            return nil
        }
        return Double(value) / 100
    }

    /// The readable lines of an sdkmanager license display: the license header
    /// (the `License <id>:` form or the numbered `3. Android SDK License`
    /// form), its agreement text, and any `Warning:` line that precedes the
    /// header. Loading chatter, progress bars, blank lines, the tool's
    /// deprecation warning and the `Accept? (y/N)` prompts are left out;
    /// `\r`-joined progress output is normalized first.
    public static func licensePromptLines(from output: String) -> [String] {
        var lines: [String] = []
        var inToolWarning = false
        var inLicenseBlock = false

        for rawLine in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("WARNING: The SDK Manager CLI tool") {
                inToolWarning = true
                continue
            }
            if inToolWarning {
                if line.hasPrefix("The 'android' binary")
                    || line.hasPrefix("To learn more about the Android CLI")
                {
                    continue
                }
                inToolWarning = false
            }

            let text = stripPrompts(from: line).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, progress(from: text) == nil else { continue }

            if isLicenseHeader(text) {
                inLicenseBlock = true
            } else if !inLicenseBlock, !text.lowercased().hasPrefix("warning:") {
                continue
            }
            lines.append(text)
        }
        return lines
    }

    private static func stripPrompts(from line: String) -> String {
        var text = line
        for pattern in promptPatterns {
            text = text.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return text
    }

    private static func isLicenseHeader(_ line: String) -> Bool {
        headerPatterns.contains {
            line.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static let promptPatterns = [
        #"accept\?\s*\(y/N\)\s*:?"#,
        #"review licenses that have not been accepted\s*\(y/N\)\s*\??"#,
        #"^\d+ of \d+ SDK package licenses not accepted\.$"#,
    ]

    private static let headerPatterns = [
        #"^(\d+/\d+:\s*)?license .+:$"#,
        #"^\d+\.\s.*(license|agreement)$"#,
    ]
}
