import Foundation
import UniformTypeIdentifiers

/// What a file or link dropped on a simulator's stage becomes:
/// each maps to one simctl call.
public enum SimulatorDrop: Sendable, Equatable {
    /// A `.app` folder: `simctl install`.
    case installApp(URL)
    /// An `.ipa` or `.zip` holding a `.app` (under `Payload/` in an `.ipa`):
    /// unzipped into a temporary folder, then installed.
    case installArchive(URL)
    /// Photos, videos and contact cards, imported together: `simctl addmedia`.
    case addMedia([URL])
    /// A certificate file (`.cer`, `.crt`, `.der`, `.pem`): after the user
    /// confirms, `simctl keychain <udid> add-root-cert`.
    case addRootCertificate(URL)
    /// A `.mobileconfig` profile: simctl cannot install one, so the
    /// certificates inside it are trusted like a dropped certificate
    /// (`ConfigurationProfile`).
    case addProfile(URL)
    /// A link (`http`, `https` or another scheme): `simctl openurl`.
    case openURL(URL)
    /// Nothing simctl can use; `reason` says so in the stage's words.
    case unsupported(URL, reason: String)
}

/// Sorts what was dropped on a simulator's stage into `SimulatorDrop`s, by
/// file extension and type, without touching the files' contents (an
/// archive's app is checked once it is unzipped, `SimulatorAppArchive`).
///
/// simctl's `addmedia` takes "photos, live photos, videos, or contacts"
/// (its help text); the media are grouped into one call so a Live Photo's
/// picture and movie arrive together, in the order they were dropped.
public enum SimulatorDropRouting {
    /// File extensions of certificates `keychain add-root-cert` reads (it
    /// takes PEM and DER, measured with both).
    public static let certificateExtensions: Set<String> = ["cer", "crt", "der", "pem"]

    /// The drops for `urls`, in the order they came, the media merged into
    /// one `addMedia` at the position of the first.
    public static func route(_ urls: [URL]) -> [SimulatorDrop] {
        var drops: [SimulatorDrop] = []
        var mediaIndex: Int?
        for url in urls {
            let drop = route(url)
            if case .addMedia(let files) = drop {
                if let index = mediaIndex, case .addMedia(let earlier) = drops[index] {
                    drops[index] = .addMedia(earlier + files)
                } else {
                    mediaIndex = drops.count
                    drops.append(drop)
                }
            } else {
                drops.append(drop)
            }
        }
        return drops
    }

    /// The drop for one URL.
    public static func route(_ url: URL) -> SimulatorDrop {
        guard url.isFileURL else {
            guard let scheme = url.scheme, !scheme.isEmpty else {
                return .unsupported(url, reason: "“\(url.absoluteString)” is not a link a simulator can open.")
            }
            return .openURL(url)
        }
        let fileExtension = url.pathExtension.lowercased()
        switch fileExtension {
        case "app":
            return .installApp(url)
        case "ipa", "zip":
            return .installArchive(url)
        default:
            break
        }
        if certificateExtensions.contains(fileExtension) {
            return .addRootCertificate(url)
        }
        if fileExtension == ConfigurationProfile.fileExtension {
            return .addProfile(url)
        }
        if isMedia(fileExtension: fileExtension) {
            return .addMedia([url])
        }
        return .unsupported(url, reason: unsupportedReason(for: url))
    }

    /// Whether files with this extension are photos, videos or contact cards.
    public static func isMedia(fileExtension: String) -> Bool {
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .vCard)
    }

    /// The stage's line for a file nothing takes.
    static func unsupportedReason(for url: URL) -> String {
        "A simulator can't use “\(url.lastPathComponent)”. Drop an app (.app, .ipa or .zip), a photo, video or contact card, a certificate, or a link."
    }
}

/// Unzips an `.ipa` or a zipped `.app` for `simctl install` and finds the
/// app inside: `Payload/<name>.app` in an `.ipa`, else a `.app` at the top
/// of the archive.
public enum SimulatorAppArchive {
    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        /// ditto could not unzip it; the text is its complaint.
        case unreadable(String)
        /// It unzipped, but holds no `.app`.
        case noApp

        public var description: String {
            switch self {
            case .unreadable(let detail): "The archive could not be unzipped: \(detail)"
            case .noApp: "The archive holds no app (.app)."
            }
        }
    }

    /// `/usr/bin/ditto`, which unzips the way the Finder does (it keeps
    /// symbolic links and permissions an app bundle needs).
    public static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")

    /// Unzips `archive` into `folder` (which must exist and be empty) and
    /// returns the app inside it.
    public static func extract(_ archive: URL, into folder: URL, timeout: Duration = .seconds(120)) async throws -> URL {
        let result = try await ProcessRunner.run(
            executable: ditto,
            arguments: ["-x", "-k", archive.path, folder.path],
            timeout: timeout
        )
        guard result.exitCode == 0 else {
            let detail = result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.unreadable(detail.isEmpty ? "ditto exited with \(result.exitCode)" : detail)
        }
        guard let app = locateApp(in: folder) else { throw Failure.noApp }
        return app
    }

    /// The app in an unzipped archive: the first `.app` (by name) under
    /// `Payload/`, else at the top level.
    public static func locateApp(in folder: URL) -> URL? {
        let fileManager = FileManager.default
        for directory in [folder.appendingPathComponent("Payload", isDirectory: true), folder] {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names.sorted() where name.lowercased().hasSuffix(".app") {
                var isDirectory: ObjCBool = false
                let candidate = directory.appendingPathComponent(name, isDirectory: true)
                if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return candidate
                }
            }
        }
        return nil
    }
}
