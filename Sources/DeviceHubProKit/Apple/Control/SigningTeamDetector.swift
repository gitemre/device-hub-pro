import Foundation
import Security

// Finds the Apple development team the standard input runner is signed with,
// from the code-signing identities in the user's keychains, so no team
// identifier is ever typed. Nothing here logs or prints a team identifier:
// `SigningTeam` and the errors describe themselves without it.

/// One code-signing certificate as the detector needs it (a value type so
/// tests inject fakes and never read the real keychain).
public struct CodeSigningCertificate: Equatable, Sendable {
    /// The subject's common name ("Apple Development: Name (XXXXXXXXXX)"; the
    /// ten characters in parentheses are the certificate's own id, NOT the team).
    public var commonName: String
    /// The subject's Organizational Unit: the team identifier.
    public var organizationalUnit: String
    /// The subject's Organization: the team's name.
    public var organization: String
    public var notBefore: Date
    public var notAfter: Date

    public init(commonName: String, organizationalUnit: String, organization: String, notBefore: Date, notAfter: Date) {
        self.commonName = commonName
        self.organizationalUnit = organizationalUnit
        self.organization = organization
        self.notBefore = notBefore
        self.notAfter = notAfter
    }
}

/// A development team found in the keychain. The identifier is reachable only
/// through `id`; the textual forms leave it out.
public struct SigningTeam: Equatable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: String
    /// The certificate's Organization name, what a picker lists.
    public let organization: String

    public init(id: String, organization: String) {
        self.id = id
        self.organization = organization
    }

    public var description: String { "SigningTeam(\(organization))" }
    public var debugDescription: String { description }
}

public enum SigningTeamDetectionError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The keychain could not be read (the status code is not kept).
    case keychainUnavailable

    public var description: String { "The code-signing identities could not be read." }
}

/// Where the detector reads certificates from.
public protocol CodeSigningCertificateSource: Sendable {
    func certificates() throws -> [CodeSigningCertificate]
}

public enum SigningTeamDetector {
    /// Distinct teams of the valid "Apple Development" / "iPhone Developer"
    /// leaf certificates, sorted by organization name.
    public static func teams(
        from source: any CodeSigningCertificateSource,
        now: Date = Date()
    ) throws -> [SigningTeam] {
        var seen = Set<String>()
        var teams: [SigningTeam] = []
        for certificate in try source.certificates() {
            guard isDevelopmentCertificate(certificate.commonName),
                  certificate.notBefore <= now, now <= certificate.notAfter else { continue }
            let id = certificate.organizationalUnit.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard isTeamID(id), seen.insert(id).inserted else { continue }
            let name = certificate.organization.trimmingCharacters(in: .whitespacesAndNewlines)
            teams.append(SigningTeam(id: id, organization: name.isEmpty ? "Apple Developer team" : name))
        }
        return teams.sorted { ($0.organization, $0.id) < ($1.organization, $1.id) }
    }

    static func isDevelopmentCertificate(_ commonName: String) -> Bool {
        commonName.hasPrefix("Apple Development:") || commonName.hasPrefix("iPhone Developer:")
    }

    /// Exactly ten upper-case letters and digits.
    public static func isTeamID(_ text: String) -> Bool {
        text.utf8.count == 10 && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) }
    }
}

/// The keychain-backed source: the identities (certificate plus private key)
/// of the user's keychains, read with the Security framework. Read only.
public struct KeychainCodeSigningCertificateSource: CodeSigningCertificateSource {
    public init() {}

    public func certificates() throws -> [CodeSigningCertificate] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let identities = result as? [SecIdentity] else {
            throw SigningTeamDetectionError.keychainUnavailable
        }
        return identities.compactMap { identity in
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
            return Self.parse(certificate)
        }
    }

    static func parse(_ certificate: SecCertificate) -> CodeSigningCertificate? {
        let keys = [
            kSecOIDX509V1SubjectName,
            kSecOIDX509V1ValidityNotBefore,
            kSecOIDX509V1ValidityNotAfter,
        ] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: [String: Any]] else { return nil }

        var subject: [String: String] = [:]
        let subjectName = values[kSecOIDX509V1SubjectName as String]?[kSecPropertyKeyValue as String] as? [[String: Any]] ?? []
        for entry in subjectName {
            guard let label = entry[kSecPropertyKeyLabel as String] as? String,
                  let value = entry[kSecPropertyKeyValue as String] as? String else { continue }
            subject[label] = value
        }
        let commonName = subject[kSecOIDCommonName as String] ?? (SecCertificateCopySubjectSummary(certificate) as String?) ?? ""
        guard let notBefore = date(values[kSecOIDX509V1ValidityNotBefore as String]?[kSecPropertyKeyValue as String]),
              let notAfter = date(values[kSecOIDX509V1ValidityNotAfter as String]?[kSecPropertyKeyValue as String])
        else { return nil }
        return CodeSigningCertificate(
            commonName: commonName,
            organizationalUnit: subject[kSecOIDOrganizationalUnitName as String] ?? "",
            organization: subject[kSecOIDOrganizationName as String] ?? "",
            notBefore: notBefore,
            notAfter: notAfter
        )
    }

    /// The validity dates come back as a number of seconds since the 2001
    /// reference date (or, on some systems, already as a `Date`).
    private static func date(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let number = value as? NSNumber { return Date(timeIntervalSinceReferenceDate: number.doubleValue) }
        return nil
    }
}

/// Resolves the team for the runner, in order: a stored value, exactly one
/// detected team (stored), the user's pick among several (stored), else
/// `PhysicalControlError.noTeam`. It runs only when the runner is needed.
public struct SigningTeamResolver: Sendable {
    public var stored: @Sendable () async -> String?
    public var store: @Sendable (String) async -> Void
    public var detect: @Sendable () async throws -> [SigningTeam]
    /// Asks the user; nil when they decline.
    public var pick: @Sendable ([SigningTeam]) async -> SigningTeam?

    public init(
        stored: @escaping @Sendable () async -> String?,
        store: @escaping @Sendable (String) async -> Void,
        detect: @escaping @Sendable () async throws -> [SigningTeam],
        pick: @escaping @Sendable ([SigningTeam]) async -> SigningTeam?
    ) {
        self.stored = stored
        self.store = store
        self.detect = detect
        self.pick = pick
    }

    public func resolve() async throws -> String {
        if let team = await stored(), SigningTeamDetector.isTeamID(team) { return team }
        let teams: [SigningTeam]
        do { teams = try await detect() } catch { throw PhysicalControlError.noTeam }
        switch teams.count {
        case 0:
            throw PhysicalControlError.noTeam
        case 1:
            await store(teams[0].id)
            return teams[0].id
        default:
            guard let chosen = await pick(teams), teams.contains(chosen) else {
                throw PhysicalControlError.unsupported("No development team was chosen, so the standard input runner is unavailable.")
            }
            await store(chosen.id)
            return chosen.id
        }
    }
}
