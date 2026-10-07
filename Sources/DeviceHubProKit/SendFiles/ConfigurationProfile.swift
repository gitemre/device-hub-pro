import Foundation

/// A `.mobileconfig` configuration profile dropped on a simulator. simctl has no
/// command that installs a profile (`simctl help` lists none, Xcode 27.0), and
/// Xcode 27's Device Hub installs profiles only through its Info inspector, so
/// the one thing the drop can do without the UI is trust the certificates the
/// profile carries (`simctl keychain … add-root-cert`); every other payload in
/// the profile (Wi-Fi, VPN, restrictions …) is left out, and the overlay says so.
public struct ConfigurationProfile: Sendable, Equatable {
    /// A certificate payload.
    public struct Certificate: Sendable, Equatable {
        /// The payload's own name (`PayloadDisplayName`), if it has one.
        public let name: String?
        public let data: Data
        /// `pem` or `cer` (DER), the extension `add-root-cert` is handed.
        public let fileExtension: String
    }

    /// The profile's `PayloadDisplayName`.
    public let displayName: String?
    public let certificates: [Certificate]
    /// The `PayloadType`s of the payloads that are not certificates.
    public let otherPayloadTypes: [String]

    /// The certificate payload types: `root` and `pkcs1` hold a DER
    /// certificate, `pem` a PEM one.
    static let derTypes: Set<String> = ["com.apple.security.root", "com.apple.security.pkcs1"]
    static let pemTypes: Set<String> = ["com.apple.security.pem"]

    public static let fileExtension = "mobileconfig"

    public static func isProfile(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == fileExtension
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unreadable(file: String, detail: String)
        case notAProfile(file: String)
        case noCertificates(file: String, otherPayloads: [String])

        public var description: String {
            switch self {
            case .unreadable(let file, let detail): "“\(file)” could not be read: \(detail)"
            case .notAProfile(let file): "“\(file)” is not a configuration profile."
            case .noCertificates(let file, let others):
                "“\(file)” holds no certificate. A simulator can't install configuration profiles; only the certificates in one can be trusted"
                    + (others.isEmpty ? "." : " (this one has \(others.joined(separator: ", "))).")
            }
        }
    }

    /// The words the drop overlay uses.
    public static let overlayNote = "Trust the profile's certificates (a simulator can't install profiles)"

    /// The `/usr/bin/security` that decodes a signed profile (a CMS envelope
    /// around the plist).
    static let security = URL(fileURLWithPath: "/usr/bin/security")

    /// Reads `url`; a profile signed with CMS is decoded with `security cms -D`.
    public static func read(_ url: URL, timeout: Duration = .seconds(20)) async throws -> ConfigurationProfile {
        let name = url.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Failure.unreadable(file: name, detail: (error as NSError).localizedDescription)
        }
        if looksLikePlist(data) { return try parse(plist: data, name: name) }
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: security,
                arguments: ["cms", "-D", "-i", url.path],
                timeout: timeout
            )
        } catch {
            throw Failure.unreadable(file: name, detail: "\(error)")
        }
        guard result.exitCode == 0 else { throw Failure.notAProfile(file: name) }
        return try parse(plist: result.standardOutput, name: name)
    }

    static func looksLikePlist(_ data: Data) -> Bool {
        let head = data.prefix(64)
        if head.starts(with: Data("bplist".utf8)) { return true }
        let text = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("<?xml") || text.hasPrefix("<plist")
    }

    /// Reads the plist of a profile called `name`.
    public static func parse(plist data: Data, name: String) throws -> ConfigurationProfile {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              root["PayloadType"] as? String == "Configuration" || root["PayloadContent"] is [Any]
        else { throw Failure.notAProfile(file: name) }
        var certificates: [Certificate] = []
        var others: [String] = []
        for case let payload as [String: Any] in root["PayloadContent"] as? [Any] ?? [] {
            let type = payload["PayloadType"] as? String ?? "unknown"
            if derTypes.contains(type) || pemTypes.contains(type) {
                guard let content = payload["PayloadContent"] as? Data, !content.isEmpty else { continue }
                let isPEM = pemTypes.contains(type) || content.starts(with: Data("-----BEGIN".utf8))
                certificates.append(Certificate(
                    name: payload["PayloadDisplayName"] as? String,
                    data: content,
                    fileExtension: isPEM ? "pem" : "cer"
                ))
            } else if !others.contains(type) {
                others.append(type)
            }
        }
        guard !certificates.isEmpty else { throw Failure.noCertificates(file: name, otherPayloads: others) }
        return ConfigurationProfile(
            displayName: root["PayloadDisplayName"] as? String,
            certificates: certificates,
            otherPayloadTypes: others
        )
    }

    /// Writes each certificate into `folder` (which exists) as a file
    /// `add-root-cert` reads, named after its payload, else the profile.
    public func writeCertificates(into folder: URL, profileName: String) throws -> [URL] {
        let base = (profileName as NSString).deletingPathExtension
        var used: Set<String> = []
        var urls: [URL] = []
        for (index, certificate) in certificates.enumerated() {
            var stem = Self.fileStem(certificate.name ?? (certificates.count == 1 ? base : "\(base) \(index + 1)"))
            while !used.insert(stem.lowercased() + "." + certificate.fileExtension).inserted { stem += " \(index + 1)" }
            let url = folder.appendingPathComponent(stem + "." + certificate.fileExtension)
            try certificate.data.write(to: url)
            urls.append(url)
        }
        return urls
    }

    static func fileStem(_ text: String) -> String {
        let cleaned = String(text.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 })
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "certificate" : String(cleaned.prefix(80))
    }
}
