import Foundation

/// Identity fields of an APK, for callers that need more than the icon.
public struct ApkMetadata: Equatable, Sendable {
    public var package: String?
    public var versionCode: String?
    public var versionName: String?
    public var label: String?

    public init(
        package: String? = nil,
        versionCode: String? = nil,
        versionName: String? = nil,
        label: String? = nil
    ) {
        self.package = package
        self.versionCode = versionCode
        self.versionName = versionName
        self.label = label
    }
}

/// Parses the output of `aapt2 dump badging`.
public enum ApkIconParsing {
    /// The package name, version and label aapt2 reported, each optional:
    /// badging omits or empties attributes for some APKs.
    public static func metadata(fromBadging output: String) -> ApkMetadata {
        ApkMetadata(
            package: packageName(fromBadging: output),
            versionCode: versionCode(fromBadging: output),
            versionName: versionName(fromBadging: output),
            label: label(fromBadging: output)
        )
    }

    /// The icon entry to extract, preferring the highest real density
    /// (`application-icon-640:` and friends) over aapt2's pseudo-densities
    /// (65534 anydpi, 65535 nodpi) and the plain `icon:` line older aapt2
    /// versions print.
    public static func iconPath(fromBadging output: String) -> String? {
        var bestReal: (density: Int, path: String)?
        var bestPseudo: (density: Int, path: String)?
        var plain: String?

        for line in output.split(separator: "\n") {
            let text = String(line)
            if let entry = densityIcon(in: text) {
                if entry.density >= pseudoDensityThreshold {
                    if bestPseudo == nil || entry.density > bestPseudo!.density {
                        bestPseudo = entry
                    }
                } else if bestReal == nil || entry.density > bestReal!.density {
                    bestReal = entry
                }
            } else if text.hasPrefix("icon:"), let value = quotedValue(in: text) {
                plain = value
            }
        }

        return bestReal?.path ?? bestPseudo?.path ?? plain
    }

    public static func packageName(fromBadging output: String) -> String? {
        guard let line = packageLine(in: output) else { return nil }
        return attribute("name", in: line)
    }

    public static func label(fromBadging output: String) -> String? {
        let lines = output.split(separator: "\n").map(String.init)
        if let plain = lines.first(where: { $0.hasPrefix("application-label:") }),
           let value = quotedValue(in: plain) {
            return value
        }
        guard let localized = lines.first(where: { $0.hasPrefix("application-label-") }) else {
            return nil
        }
        return quotedValue(in: localized)
    }

    static func versionCode(fromBadging output: String) -> String? {
        versionAttribute("versionCode", fromBadging: output)
    }

    static func versionName(fromBadging output: String) -> String? {
        versionAttribute("versionName", fromBadging: output)
    }

    private static let pseudoDensityThreshold = 65_534

    private static func packageLine(in output: String) -> String? {
        output.split(separator: "\n")
            .first(where: { $0.hasPrefix("package:") })
            .map(String.init)
    }

    private static func versionAttribute(_ name: String, fromBadging output: String) -> String? {
        guard let line = packageLine(in: output) else { return nil }
        // The leading space keeps `versionCode` from matching
        // `platformBuildVersionCode`.
        guard let value = attribute(" \(name)", in: line), !value.isEmpty else { return nil }
        return value
    }

    /// `application-icon-<density>:'<path>'` with the density aapt2 resolved
    /// the icon at.
    private static func densityIcon(in line: String) -> (density: Int, path: String)? {
        let prefix = "application-icon-"
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count)
        guard let colon = rest.firstIndex(of: ":"), let density = Int(rest[..<colon]),
              let path = quotedValue(in: String(rest[colon...])) else {
            return nil
        }
        return (density, path)
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        guard let start = line.range(of: "\(name)='") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "'") else { return nil }
        return String(rest[..<end])
    }

    private static func quotedValue(in line: String) -> String? {
        guard let open = line.firstIndex(of: "'"),
              let close = line.lastIndex(of: "'"),
              open < close else {
            return nil
        }
        return String(line[line.index(after: open)..<close])
    }
}
