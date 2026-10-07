import Foundation
import ImageIO

/// Failures of the APK icon pipeline.
public enum ApkIconError: Error, Equatable, CustomStringConvertible {
    case toolNotFound
    case badgingFailed(exitCode: Int32, message: String)
    case extractionFailed(entry: String, message: String)

    public var description: String {
        switch self {
        case .toolNotFound:
            return "aapt2 was not found. Install Android SDK build-tools or set DHP_AAPT2."
        case .badgingFailed(let exitCode, let message):
            return "aapt2 dump badging failed (\(exitCode)): \(message)"
        case .extractionFailed(let entry, let message):
            return "extracting '\(entry)' from the APK failed: \(message)"
        }
    }
}

/// Extracts an app icon from an APK and caches it as a PNG.
public enum ApkIconExtractor {
    /// The cached icon for `apk`, or nil when the APK carries no raster icon.
    ///
    /// `aapt2 dump badging` names the best icon; adaptive XML icons fall back
    /// to the highest-density `ic_launcher`/`ic_launcher_round` raster in the
    /// archive's mipmap folders (other rasters are shortcut/notification
    /// artwork, not the app icon), then to the XML's layers resolved through
    /// `resources.arsc` — the only route to rasters stored under obfuscated
    /// `res/*` names — composited as the launcher shows them (foreground
    /// raster over the background color or raster). The cache file is
    /// `<package>-<version>.png`, keyed on the badging
    /// `versionCode` (monotonic across updates and the version ADB reports
    /// for `pm list packages --show-versioncode`), then `versionName`, then
    /// the APK's filename stem. A cache hit skips the archive extraction;
    /// callers that already know package and version can check
    /// `cacheFileURL(forPackage:version:in:)` to skip the badging run too.
    public static func icon(
        forAPKAt apk: URL,
        cacheDirectory: URL,
        tool: URL? = nil
    ) async throws -> URL? {
        let toolURL = tool ?? ApkToolLocator.locate()
        guard let toolURL, FileManager.default.isExecutableFile(atPath: toolURL.path) else {
            throw ApkIconError.toolNotFound
        }

        let badging = try await badgingOutput(forAPKAt: apk, tool: toolURL)
        let stem = apk.deletingPathExtension().lastPathComponent
        let package = ApkIconParsing.packageName(fromBadging: badging) ?? stem
        let version = ApkIconParsing.versionCode(fromBadging: badging)
            ?? ApkIconParsing.versionName(fromBadging: badging)
            ?? stem
        // The app's own name rides along with its icon (`cachedLabel`), also
        // for an app whose icon cannot be extracted.
        if let label = ApkIconParsing.label(fromBadging: badging) {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? Data(label.utf8).write(
                to: labelFileURL(forPackage: package, version: version, in: cacheDirectory), options: .atomic
            )
        }
        guard let iconPath = ApkIconParsing.iconPath(fromBadging: badging) else { return nil }

        let cacheFile = cacheFileURL(forPackage: package, version: version, in: cacheDirectory)
        if FileManager.default.fileExists(atPath: cacheFile.path) {
            // A pre-fix build could have written a non-raster (an adaptive XML
            // named as the icon) under the `.png` name; serving it would keep
            // every later reader failing. Only a decodable raster is a hit; a
            // poisoned file is dropped and extraction runs instead.
            if let cached = try? Data(contentsOf: cacheFile), isDecodableRasterPayload(cached) {
                return cacheFile
            }
            try? FileManager.default.removeItem(at: cacheFile)
        }

        let data: Data?
        if iconPath.lowercased().hasSuffix(".xml") {
            data = try await adaptiveIconData(forXMLAt: iconPath, in: apk)
        } else {
            data = try await rasterData(ofArchiveEntry: iconPath, in: apk)
        }
        // Badging can name an XML or a truncated payload as the icon; writing
        // that under the `.png` cache name would poison every later read.
        guard let data else { return nil }

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try data.write(to: cacheFile, options: .atomic)
        return cacheFile
    }

    /// Whether `entry` may be passed to `unzip` as one literal archive member.
    /// `unzip` reads `*`, `?` and `[...]` as match patterns and `\` as its
    /// pattern escape, so a badging-supplied path containing them could pull
    /// an unrelated entry; a leading `-` would be read as an option.
    static func isExactArchiveMember(_ entry: String) -> Bool {
        guard !entry.isEmpty, !entry.hasPrefix("-") else { return false }
        return !entry.contains { "*?[\\".contains($0) }
    }

    /// Whether `data` starts with the magic bytes of a raster format the
    /// `.png` cache may hold: PNG, JPEG, WebP, GIF or BMP. Anything else — an
    /// adaptive XML, junk from a malformed APK — must never be cached (or
    /// served from the cache) as an icon.
    public static func isRasterPayload(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 8, Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            return true
        }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return true
        }
        if bytes.count >= 12,
           Array(bytes[0..<4]) == Array("RIFF".utf8),
           Array(bytes[8..<12]) == Array("WEBP".utf8) {
            return true
        }
        if bytes.count >= 6,
           Array(bytes[0..<4]) == Array("GIF8".utf8),
           bytes[4] == 0x37 || bytes[4] == 0x39,
           bytes[5] == 0x61 {
            return true
        }
        if bytes.count >= 2, bytes[0] == 0x42, bytes[1] == 0x4D {
            return true
        }
        return false
    }

    /// Whether `data` is a raster the cache may trust: a known magic *and* a
    /// first frame ImageIO can actually decode. A truncated payload passes
    /// the magic sniff but must neither be served from nor written to the
    /// cache. Exposed so callers reading the cache file directly (the app's
    /// icon store) clear the same bar as extraction.
    public static func isDecodableRasterPayload(_ data: Data) -> Bool {
        guard isRasterPayload(data) else { return false }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return false
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    /// The identity fields `aapt2 dump badging` reports for a local APK file
    /// (the install recents list). Throws `ApkIconError` exactly like
    /// `icon(forAPKAt:cacheDirectory:tool:)`; it never touches the icon cache.
    public static func metadata(
        forAPKAt apk: URL,
        tool: URL? = nil
    ) async throws -> ApkMetadata {
        let toolURL = tool ?? ApkToolLocator.locate()
        guard let toolURL, FileManager.default.isExecutableFile(atPath: toolURL.path) else {
            throw ApkIconError.toolNotFound
        }
        return ApkIconParsing.metadata(
            fromBadging: try await badgingOutput(forAPKAt: apk, tool: toolURL)
        )
    }

    /// The cache location for an app icon, sanitized for the filesystem.
    public static func cacheFileURL(
        forPackage package: String,
        version: String,
        in cacheDirectory: URL
    ) -> URL {
        cacheDirectory.appendingPathComponent("\(sanitized(package))-\(sanitized(version)).png")
    }

    /// Where `icon(forAPKAt:…)` keeps the app's label beside its icon.
    public static func labelFileURL(forPackage package: String, version: String, in cacheDirectory: URL) -> URL {
        cacheDirectory.appendingPathComponent("\(sanitized(package))-\(sanitized(version)).label")
    }

    /// The app's name as badging reported it when its icon was extracted;
    /// nil when not extracted yet or the APK names none.
    public static func cachedLabel(forPackage package: String, version: String, in cacheDirectory: URL) -> String? {
        guard let data = try? Data(contentsOf: labelFileURL(forPackage: package, version: version, in: cacheDirectory)),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }

    private static let unzipURL = URL(fileURLWithPath: "/usr/bin/unzip")

    private static func badgingOutput(forAPKAt apk: URL, tool: URL) async throws -> String {
        let result = try await ProcessRunner.run(
            executable: tool,
            arguments: ["dump", "badging", apk.path]
        )
        guard result.exitCode == 0 else {
            throw ApkIconError.badgingFailed(
                exitCode: result.exitCode,
                message: result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.standardOutputText
    }

    private static func archiveData(of entry: String, in apk: URL) async throws -> Data {
        let result = try await ProcessRunner.run(
            executable: unzipURL,
            arguments: ["-p", apk.path, entry]
        )
        guard result.exitCode == 0, !result.standardOutput.isEmpty else {
            throw ApkIconError.extractionFailed(
                entry: entry,
                message: result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.standardOutput
    }

    private static let resourceTableEntry = "resources.arsc"

    /// The decodable raster `entry` holds, or nil when the member cannot be
    /// extracted or is not a raster. `unzip` treats `*`, `?` and `[...]` as
    /// match patterns, so only a literal member (see `isExactArchiveMember`)
    /// is ever handed to it.
    private static func rasterData(ofArchiveEntry entry: String, in apk: URL) async throws -> Data? {
        guard isExactArchiveMember(entry) else { return nil }
        let data = try await archiveData(of: entry, in: apk)
        return isDecodableRasterPayload(data) ? data : nil
    }

    /// The raster bytes an adaptive (`android:icon` XML) APK should show.
    ///
    /// The mipmap scan runs first: when the archive still carries an
    /// `ic_launcher` raster, that full icon is the best answer. Otherwise the
    /// XML's layer drawables are resolved through the resource table, which
    /// reaches rasters stored under obfuscated `res/*` names (a shrunk release build,
    /// Chrome) that no name-based scan can find.
    ///
    /// An adaptive icon is rendered as the launcher shows it (see
    /// `AdaptiveIconRenderer`): the foreground raster over the background
    /// color or raster, cropped to the visible viewport. The foreground is
    /// the identifying artwork, so without a raster foreground (a vector)
    /// there is no icon — never a lone background (a flat square) or
    /// monochrome mask in its place. An XML that is not layered (an `<inset>`
    /// or `<layer-list>` around one drawable) shows that drawable's raster.
    /// Within a reference candidates go densest first, skipping members that
    /// are missing or are not decodable rasters (vectors, split-APK
    /// omissions).
    private static func adaptiveIconData(forXMLAt entry: String, in apk: URL) async throws -> Data? {
        if let raster = try await highestDensityMipmap(in: apk),
           let data = try? await rasterData(ofArchiveEntry: raster, in: apk) {
            return data
        }

        guard isExactArchiveMember(entry),
              let xml = try? await archiveData(of: entry, in: apk),
              let manifest = AdaptiveIconManifest(data: xml),
              let tableData = try? await archiveData(of: resourceTableEntry, in: apk),
              let table = ApkResourceTable(data: tableData) else {
            return nil
        }

        let foregrounds = manifest.references.filter { $0.layer == .foreground }
        guard !foregrounds.isEmpty else {
            let others = manifest.references.filter { $0.layer == .other }
            return await firstRaster(of: others, table: table, in: apk)
        }
        guard let foreground = await firstRaster(of: foregrounds, table: table, in: apk) else {
            return nil
        }
        let background = await backgroundLayer(
            of: manifest.references.filter { $0.layer == .background },
            table: table,
            in: apk
        )
        return AdaptiveIconRenderer.render(foreground: foreground, background: background)
    }

    /// The first decodable raster the references name, in document order and
    /// densest first within a reference.
    private static func firstRaster(
        of references: [AdaptiveIconManifest.Reference],
        table: ApkResourceTable,
        in apk: URL
    ) async -> Data? {
        for reference in references {
            for candidate in filePaths(of: reference.drawable, table: table) {
                if let data = try? await rasterData(ofArchiveEntry: candidate.path, in: apk) {
                    return data
                }
            }
        }
        return nil
    }

    /// The background the launcher would paint: a color (literal or
    /// `@color/…`), else a raster, else nothing (a vector or gradient this
    /// renderer cannot draw).
    private static func backgroundLayer(
        of references: [AdaptiveIconManifest.Reference],
        table: ApkResourceTable,
        in apk: URL
    ) async -> AdaptiveIconRenderer.Background {
        for reference in references {
            switch reference.drawable {
            case .color(let argb):
                return .color(argb)
            case .resource(let id):
                if let argb = table.color(for: id) {
                    return .color(argb)
                }
            case .file:
                break
            }
        }
        if let raster = await firstRaster(of: references, table: table, in: apk) {
            return .raster(raster)
        }
        return .none
    }

    private static func filePaths(
        of drawable: AdaptiveIconManifest.Drawable,
        table: ApkResourceTable
    ) -> [ApkResourceTable.FilePath] {
        switch drawable {
        case .resource(let id):
            return table.filePaths(for: id)
        case .file(let path):
            return [ApkResourceTable.FilePath(path: path, density: 0)]
        case .color:
            return []
        }
    }

    /// The highest-density `res/mipmap-*` `ic_launcher`/`ic_launcher_round`
    /// PNG/WebP, used when badging points at an adaptive XML icon. Only the
    /// exact launcher stems are acceptable: a `contains` match would let
    /// shortcut artwork (`ic_launcher_gallery`) or notification glyphs stand
    /// in for the app icon. At equal density the lexicographically first
    /// path wins.
    private static func highestDensityMipmap(in apk: URL) async throws -> String? {
        let result = try await ProcessRunner.run(
            executable: unzipURL,
            arguments: ["-Z1", apk.path]
        )
        guard result.exitCode == 0 else {
            throw ApkIconError.extractionFailed(
                entry: "",
                message: result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return highestDensityMipmap(inListing: result.standardOutputText)
    }

    /// The pick of ``highestDensityMipmap(in:)`` from an `unzip -Z1` listing
    /// (one archive member per line).
    static func highestDensityMipmap(inListing listing: String) -> String? {
        var best: (entry: String, density: Int)?
        for entry in listing.split(separator: "\n").map(String.init) {
            guard let candidate = mipmapRaster(entry) else { continue }
            let isBetter = best == nil
                || candidate.density > best!.density
                || (candidate.density == best!.density && candidate.entry < best!.entry)
            if isBetter {
                best = candidate
            }
        }
        return best?.entry
    }

    /// A `res/mipmap-<bucket>/ic_launcher[.round].(png|webp)` archive entry
    /// with its density, or nil for anything else.
    private static func mipmapRaster(
        _ entry: String
    ) -> (entry: String, density: Int)? {
        let parts = entry.split(separator: "/")
        guard parts.count >= 3,
              parts[0] == "res",
              parts[parts.count - 2].hasPrefix("mipmap-") else {
            return nil
        }
        let name = String(parts[parts.count - 1])
        guard let ext = name.split(separator: ".").last?.lowercased(),
              ext == "png" || ext == "webp" else {
            return nil
        }
        let bucket = parts[parts.count - 2].dropFirst("mipmap-".count)
        guard let density = densityRank(String(bucket)) else { return nil }

        let stem = name.split(separator: ".").first.map(String.init)?.lowercased() ?? ""
        // Adaptive layers are not a usable icon on their own; every other
        // stem is unrelated artwork (shortcut/notification glyphs).
        guard stem == "ic_launcher" || stem == "ic_launcher_round" else { return nil }
        return (entry, density)
    }

    private static func densityRank(_ bucket: String) -> Int? {
        // Compiled APKs qualify density buckets with a version:
        // `mipmap-xxxhdpi-v4`. `anydpi-v26` strips to `anydpi`, which still
        // carries no usable rank.
        let base = strippingVersionQualifier(bucket)
        switch base {
        case "ldpi": return 120
        case "mdpi": return 160
        case "hdpi": return 240
        case "xhdpi": return 320
        case "xxhdpi": return 480
        case "xxxhdpi": return 640
        default:
            // Numeric buckets like `640dpi`.
            let digits = base.prefix(while: { $0.isNumber })
            guard !digits.isEmpty, base.dropFirst(digits.count).hasPrefix("dpi") else {
                return nil
            }
            return Int(digits)
        }
    }

    private static func strippingVersionQualifier(_ bucket: String) -> String {
        guard let range = bucket.range(of: "-v", options: .backwards) else { return bucket }
        let suffix = bucket[range.upperBound...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return bucket }
        return String(bucket[..<range.lowerBound])
    }

    private static func sanitized(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let cleaned = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "unknown" : cleaned
    }
}
