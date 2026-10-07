import Foundation

/// The minimum Android API each SDK device profile supports, read from the
/// `devices/nexus.xml` bundled inside the cmdline-tools jars. The table is
/// optional: when cmdline-tools is absent every device is treated as having
/// no minimum.
public struct PixelMinApiTable: Sendable, Equatable {
    public struct Entry: Sendable, Hashable {
        public let minApi: String
        public let playstoreEnabled: Bool

        public init(minApi: String, playstoreEnabled: Bool) {
            self.minApi = minApi
            self.playstoreEnabled = playstoreEnabled
        }
    }

    /// Device id (`pixel_9_pro`) → entry.
    public let entries: [String: Entry]

    public init(entries: [String: Entry]) {
        self.entries = entries
    }

    /// The profile definitions the SDK bundles; every one carries the same
    /// `<d:api-level>` element (`36.1-`, or a bare `-` for no minimum).
    static let profileFiles = [
        "nexus.xml", "devices.xml", "wear.xml", "tv.xml", "automotive.xml", "desktop.xml", "xr.xml",
    ]

    /// The minimum API of the profile `id`; nil when the profile has no
    /// entry or declares none (a bare `-`).
    public func minApi(forProfile id: String) -> String? {
        guard let value = entries[id]?.minApi, !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Loading

    /// Reads the first jar that yields a parseable `nexus.xml` under the
    /// SDK's cmdline-tools revisions; nil when nothing is readable.
    public static func load(
        sdkRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> PixelMinApiTable? {
        let manager = FileManager.default
        let tools = sdkRoot.appendingPathComponent("cmdline-tools", isDirectory: true)
        let revisions = ((try? manager.contentsOfDirectory(atPath: tools.path)) ?? []).sorted()
        for revision in revisions {
            let lib = tools.appendingPathComponent("\(revision)/lib/sdklib", isDirectory: true)
            for jar in ["tools.sdklib.jar", "sdklib.core.jar"] {
                let jarURL = lib.appendingPathComponent(jar)
                guard manager.fileExists(atPath: jarURL.path) else { continue }
                var merged: [String: Entry] = [:]
                for file in profileFiles {
                    guard let xml = await unzipEntry(
                        jar: jarURL,
                        entry: "com/android/sdklib/devices/\(file)",
                        environment: environment
                    ) else {
                        continue
                    }
                    // The first file to name a profile wins (nexus.xml first).
                    merged.merge(parse(nexusXML: xml).entries) { first, _ in first }
                }
                if !merged.isEmpty { return PixelMinApiTable(entries: merged) }
            }
        }
        return nil
    }

    private static func unzipEntry(
        jar: URL,
        entry: String,
        environment: [String: String]
    ) async -> String? {
        guard let result = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-p", jar.path, entry],
            environment: environment
        ), result.exitCode == 0, !result.standardOutput.isEmpty else {
            return nil
        }
        return String(data: result.standardOutput, encoding: .utf8)
    }

    // MARK: - Parsing

    /// Scans the machine-generated `<d:device>` blocks for id, api-level and
    /// playstore flag.
    public static func parse(nexusXML: String) -> PixelMinApiTable {
        var entries: [String: Entry] = [:]
        for block in blocks(in: nexusXML) {
            guard let id = firstTag("d:id", in: block),
                  let rawApi = firstTag("d:api-level", in: block)
            else {
                continue
            }
            let minApi = rawApi.hasSuffix("-") ? String(rawApi.dropLast()) : rawApi
            let playstore = firstTag("d:playstore-enabled", in: block) == "true"
            entries[id] = Entry(minApi: minApi, playstoreEnabled: playstore)
        }
        return PixelMinApiTable(entries: entries)
    }

    private static func blocks(in xml: String) -> [Substring] {
        var blocks: [Substring] = []
        var search = xml.startIndex..<xml.endIndex
        while let open = xml.range(of: "<d:device", range: search),
              let close = xml.range(of: "</d:device>", range: open.upperBound..<xml.endIndex)
        {
            blocks.append(xml[open.upperBound..<close.lowerBound])
            search = close.upperBound..<xml.endIndex
        }
        return blocks
    }

    private static func firstTag(_ name: String, in block: Substring) -> String? {
        guard let open = block.range(of: "<\(name)>"),
              let close = block.range(of: "</\(name)>", range: open.upperBound..<block.endIndex)
        else {
            return nil
        }
        let value = block[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - Comparison

    /// Compares API strings numerically (`"36.1"` > `"36"`), ignoring an
    /// `android-` prefix and any `-` suffix after the version: `sdkmanager
    /// --list` offers SDK-extension images (`android-35-ext15`, API 35 with
    /// extension level 15) and previews (`android-37.2-beta1`) next to the
    /// plain `android-35`. A codename (`android-CANARY`,
    /// `android-canary-20260909`) has no number and compares as 0.
    public static func compare(_ left: String, _ right: String) -> ComparisonResult {
        let lhs = components(left)
        let rhs = components(right)
        if lhs.major != rhs.major {
            return lhs.major < rhs.major ? .orderedAscending : .orderedDescending
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    private static func components(_ api: String) -> (major: Int, minor: Int) {
        let trimmed = api.hasPrefix("android-") ? String(api.dropFirst("android-".count)) : api
        let version = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .first ?? ""
        let parts = version.split(separator: ".")
        let major = Int(parts.first ?? "") ?? 0
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return (major, minor)
    }
}
