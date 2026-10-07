import Foundation

/// Google's SDK repository listing (`repository2-3.xml`): what each package
/// is, and where its archive for this Mac is, with the size and checksum the
/// download is verified against. Only what the guided install reads is kept.
public struct AndroidRepositoryManifest: Equatable, Sendable {
    public struct Archive: Equatable, Sendable {
        public let url: String
        public let size: Int64
        public let checksumType: String
        public let checksum: String
        /// `macosx`, `linux`, `windows`, or nil for an OS-independent archive.
        public let hostOS: String?
        /// `x64`, `aarch64`, or nil for any architecture.
        public let hostArch: String?
    }

    public struct Package: Equatable, Sendable {
        public let path: String
        public let displayName: String
        /// `major.minor.micro` (missing parts are 0).
        public let revision: String
        public let isObsolete: Bool
        public let channel: String?
        /// The id of the license the package is under (`android-sdk-license`).
        public let licenseRef: String?
        public let archives: [Archive]
    }

    /// The directory the archives' relative URLs resolve against.
    public static let repositoryBaseURL = URL(string: "https://dl.google.com/android/repository/")!
    public static let repositoryURL = URL(string: "https://dl.google.com/android/repository/repository2-3.xml")!

    public let packages: [Package]
    /// The license texts by id, as Google's listing carries them.
    public let licenses: [String: String]

    /// The stable (or unchannelled), non-obsolete package at `path`.
    public func package(path: String) -> Package? {
        packages.first { $0.path == path && !$0.isObsolete && ($0.channel == nil || $0.channel == "stable") }
    }

    /// The archive of `package` that runs on a Mac of `arch` (`aarch64` or
    /// `x64`): an exact `macosx` + arch match first, then a `macosx` one for
    /// any architecture.
    public static func macArchive(of package: Package, arch: String) -> Archive? {
        let mac = package.archives.filter { $0.hostOS == "macosx" }
        return mac.first { $0.hostArch == arch } ?? mac.first { $0.hostArch == nil }
    }

    public static func resolvedURL(of archive: Archive) -> URL? {
        URL(string: archive.url, relativeTo: repositoryBaseURL)?.absoluteURL
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case malformed(String)

        public var description: String {
            switch self {
            case .malformed(let detail): return "Google's SDK catalog could not be read (\(detail))."
            }
        }
    }

    public static func parse(_ data: Data) throws -> AndroidRepositoryManifest {
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw ParseError.malformed(parser.parserError?.localizedDescription ?? "invalid XML")
        }
        let channels = delegate.channels
        let packages = delegate.packages.map { raw in
            Package(
                path: raw.path,
                displayName: raw.displayName,
                revision: raw.revision,
                isObsolete: raw.obsolete,
                channel: raw.channelRef.flatMap { channels[$0] },
                licenseRef: raw.licenseRef,
                archives: raw.archives
            )
        }
        guard !packages.isEmpty else { throw ParseError.malformed("no packages") }
        return AndroidRepositoryManifest(packages: packages, licenses: delegate.licenses)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        struct RawPackage {
            var path = ""
            var displayName = ""
            var obsolete = false
            var channelRef: String?
            var licenseRef: String?
            var major = "0", minor = "0", micro = "0"
            var archives: [Archive] = []
            var revision: String { "\(major).\(minor).\(micro)" }
        }

        struct RawArchive {
            var url = "", checksumType = "", checksum = ""
            var size: Int64 = 0
            var hostOS: String?
            var hostArch: String?
        }

        var channels: [String: String] = [:]
        var licenses: [String: String] = [:]
        private var licenseID: String?
        var packages: [RawPackage] = []
        private var current: RawPackage?
        private var archive: RawArchive?
        private var path: [String] = []
        private var text = ""
        private var channelID: String?
        private var checksumType = ""

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String] = [:]
        ) {
            path.append(name)
            text = ""
            switch name {
            case "channel": channelID = attributes["id"]
            case "remotePackage":
                var package = RawPackage()
                package.path = attributes["path"] ?? ""
                package.obsolete = attributes["obsolete"] == "true"
                current = package
            case "channelRef": current?.channelRef = attributes["ref"]
            case "license": licenseID = attributes["id"]
            case "uses-license": current?.licenseRef = attributes["ref"]
            case "archive": archive = RawArchive()
            case "checksum": checksumType = attributes["type"] ?? ""
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
            qualifiedName: String?
        ) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = path.dropLast().last
            switch name {
            case "channel":
                if let id = channelID { channels[id] = value }
            case "license":
                if let id = licenseID { licenses[id] = value }
            case "display-name": if parent == "remotePackage" { current?.displayName = value }
            case "major": if parent == "revision" { current?.major = value }
            case "minor": if parent == "revision" { current?.minor = value }
            case "micro": if parent == "revision" { current?.micro = value }
            case "size": archive?.size = Int64(value) ?? 0
            case "checksum":
                archive?.checksum = value
                archive?.checksumType = checksumType
            case "url": if parent == "complete" { archive?.url = value }
            case "host-os": archive?.hostOS = value
            case "host-arch": archive?.hostArch = value
            case "archive":
                if let raw = archive {
                    current?.archives.append(Archive(
                        url: raw.url, size: raw.size, checksumType: raw.checksumType,
                        checksum: raw.checksum, hostOS: raw.hostOS, hostArch: raw.hostArch
                    ))
                }
                archive = nil
            case "remotePackage":
                if let package = current { packages.append(package) }
                current = nil
            default: break
            }
            path.removeLast()
        }
    }
}
