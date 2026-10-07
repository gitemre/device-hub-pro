import Foundation

/// The simctl calls behind a simulator's Apps inspector, the files and
/// links dropped on its stage and the Device menu's Open URL…: install,
/// uninstall, media import, root certificates and URLs. Every call names one
/// UDID and runs the real simctl through `checked`, so a failure arrives as
/// a decoded `SimctlFailure`.
///
/// Measured on Xcode 27.0 (CoreSimulator 1171.7) against an iOS 27.0
/// iPhone 17 Pro in the default set (`SimctlAppsFixtureTests`):
/// - all of them need a booted device: `install` and `listapps` on a shut-down
///   one fail with SimError 405 ("Unable to lookup in current state:
///   Shutdown", `SimctlFailure.Kind.invalidState`), `addmedia` with
///   LaunchdSimError 133 ("Multiple errors were returned");
/// - `install` of a device build fails with IXUserPresentableErrorDomain 4,
///   worded in the Mac's language, after copying the app (1.5 s);
/// - `uninstall` of an app that is not installed exits 0;
/// - the first `addmedia` into a new simulator's photo library took 32.3 s,
///   the next 0.13 s (the spike's device: 0.27 s);
/// - `keychain … add-root-cert` takes PEM and DER; any other file fails with
///   NSPOSIXErrorDomain 22 ("Certificate is not a supported CER or PEM
///   certificate file");
/// - `openurl` of a scheme no app handles fails with
///   LSApplicationWorkspaceErrorDomain 115; a custom scheme an installed app
///   handles makes iOS ask "Open in “<app>”?" on the simulator first.
extension SimctlClient {
    /// The bound for `install`: 5.4 s for a first install of a small app on
    /// a loaded Mac, 1.1 s for the next; a large app copies for longer.
    public static let installTimeout: Duration = .seconds(180)

    /// The bound for `addmedia`: the first import into a new simulator's
    /// photo library took 32.3 s (the library is set up then), the next 0.13 s.
    public static let mediaImportTimeout: Duration = .seconds(120)

    /// Installs a simulator build of an app (`install <udid> <app>`),
    /// replacing an installed app with the same bundle identifier.
    public func install(udid: String, app: URL) async throws {
        try Self.validateUDID(udid)
        try Self.validateFile(app, role: "app")
        try await checked(["install", udid, app.path], timeout: Self.installTimeout)
    }

    /// Uninstalls an app (`uninstall <udid> <bundle>`). simctl exits 0 when no
    /// app with that identifier is installed.
    public func uninstall(udid: String, bundleIdentifier: String) async throws {
        try Self.validateUDID(udid)
        try Self.validateBundleIdentifier(bundleIdentifier)
        try await checked(["uninstall", udid, bundleIdentifier])
    }

    /// Imports photos, videos and contact cards into the simulator's
    /// libraries (`addmedia <udid> <file>…`), in one call: simctl pairs a
    /// Live Photo's picture and movie itself. A file it cannot import fails
    /// the call with LaunchdSimError 133; its own line on stderr names it.
    public func addMedia(udid: String, files: [URL]) async throws {
        try Self.validateUDID(udid)
        guard !files.isEmpty else {
            throw SimctlClientError.invalidValue("no media files")
        }
        for file in files {
            try Self.validateFile(file, role: "media file")
        }
        try await checked(["addmedia", udid] + files.map(\.path), timeout: Self.mediaImportTimeout)
    }

    /// Adds `certificate` (PEM or DER) to the simulator's trusted roots
    /// (`keychain <udid> add-root-cert <file>`): every TLS connection in the
    /// simulator then trusts what it signs, so callers confirm first.
    /// `keychain reset` does not remove a trusted root again (measured).
    public func addRootCertificate(udid: String, certificate: URL) async throws {
        try Self.validateUDID(udid)
        try Self.validateFile(certificate, role: "certificate")
        try await checked(["keychain", udid, "add-root-cert", certificate.path])
    }

    /// Removes the keychain items (saved logins, keys) from the simulator
    /// (`keychain <udid> reset`). It does not remove a trusted root added with
    /// `addRootCertificate(udid:certificate:)`. Callers confirm first.
    public func resetKeychain(udid: String) async throws {
        try Self.validateUDID(udid)
        try await checked(["keychain", udid, "reset"])
    }

    /// Opens `url` in the simulator (`openurl <udid> <url>`): a web link in
    /// Safari, a custom scheme in the app that declares it (a dropped link,
    /// or the Open URL sheet's, `readLink(_:)`). simctl answers a scheme no app
    /// handles with `LSApplicationWorkspaceErrorDomain` 115 (exit 115) and
    /// text it cannot read as a URL with OSStatus −50 (exit 206). A file URL,
    /// or one without an RFC 3986 scheme (so it can never read as an
    /// option), is refused here: simctl opens links, not host files.
    public func openURL(udid: String, url: URL) async throws {
        try Self.validateUDID(udid)
        guard !url.isFileURL, Self.hasScheme(url.absoluteString) else {
            throw SimctlClientError.invalidValue("'\(url.absoluteString)' is not a link")
        }
        try await checked(["openurl", udid, url.absoluteString])
    }

    /// Why typed text is not a link `openURL(udid:url:)` takes (`readLink`).
    public enum LinkRefusal: Error, Equatable, Sendable {
        /// No RFC 3986 scheme: "example.com".
        case noScheme
        /// A `file:` URL: simctl opens links, not host files.
        case hostFile
        /// A scheme, but Foundation reads no URL from the rest: a space or
        /// "^" in the host, a port that is not a number, an unclosed "[".
        case unreadable
    }

    /// The link typed `text` names, for `openURL(udid:url:)`: trimmed, with
    /// an RFC 3986 scheme, not a file URL, and read by `URL(string:)`; the
    /// reason otherwise. Characters a URL cannot hold in its path, query or
    /// fragment (a space, "ş") are percent-encoded, as simctl does to its
    /// own argument (it answered `not a url` with "failed to open
    /// not%20a%20url", `simctl-openurl-invalid.stderr.txt`), so the app
    /// that opens it receives the same URL.
    public static func readLink(_ text: String) -> Result<URL, LinkRefusal> {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasScheme(text) else { return .failure(.noScheme) }
        // Before `URL(string:)`, which reads no URL from "file://a b/x".
        guard text.prefix(while: { $0 != ":" }).lowercased() != "file" else { return .failure(.hostFile) }
        guard let url = URL(string: text) else { return .failure(.unreadable) }
        guard !url.isFileURL else { return .failure(.hostFile) }
        return .success(url)
    }

    /// `readLink`'s link, or nil.
    public static func link(_ text: String) -> URL? {
        try? readLink(text).get()
    }

    /// Whether `text` starts with an RFC 3986 scheme and its colon
    /// (`ALPHA *(ALPHA / DIGIT / "+" / "-" / ".") ":"`).
    public static func hasScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":"), colon > text.startIndex else { return false }
        let scheme = text[..<colon]
        guard let first = scheme.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic else { return false }
        return scheme.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || "+-.".unicodeScalars.contains(scalar))
        }
    }

    /// A host file simctl is handed: an absolute file URL (so it can never
    /// be read as an option or a selector).
    static func validateFile(_ url: URL, role: String) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw SimctlClientError.invalidValue("the \(role) '\(url.absoluteString)' is not a file")
        }
    }

    /// A bundle identifier: not empty, no spaces, not an option.
    static func validateBundleIdentifier(_ identifier: String) throws {
        guard !identifier.isEmpty,
              !identifier.hasPrefix("-"),
              !identifier.contains(where: { $0.isWhitespace || $0.isNewline })
        else {
            throw SimctlClientError.invalidValue("bundle identifier '\(identifier)'")
        }
    }
}
