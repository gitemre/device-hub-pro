import Foundation

public enum AvdmanagerError: Error, CustomStringConvertible {
    case avdmanagerNotFound
    case javaNotFound
    case commandFailed(String)
    /// An AVD with this name (ignoring case) already exists; creating it
    /// would replace the existing AVD and its data.
    case avdAlreadyExists(String)

    public var description: String {
        switch self {
        case .avdmanagerNotFound:
            return "avdmanager was not found. Install the Android SDK command-line tools."
        case .javaNotFound:
            return "Java is required to create AVDs but no working runtime was found."
        case .commandFailed(let reason):
            return reason
        case .avdAlreadyExists(let name):
            return "An AVD named “\(name)” already exists. Choose a different name — creating it would replace the existing device and its data."
        }
    }
}

/// One `avdmanager list device` entry: the `-d` id and its display name.
public struct AvdDevice: Sendable, Hashable {
    public let id: String
    public let name: String
    /// The `Tag :` line (`android-wear`, `ai-glasses`, ...); nil for the
    /// phones and tablets, whose definitions carry none.
    public let tag: String?

    public init(id: String, name: String, tag: String? = nil) {
        self.id = id
        self.name = name
        self.tag = tag
    }
}

/// An installed system image, as a `-k` package path.
public struct SystemImage: Sendable, Hashable, Identifiable {
    /// `system-images;android-35;google_apis;arm64-v8a`
    public let package: String
    /// `android-35`
    public let api: String
    /// `google_apis`
    public let tag: String
    /// `arm64-v8a`
    public let abi: String

    public init(package: String, api: String, tag: String, abi: String) {
        self.package = package
        self.api = api
        self.tag = tag
        self.abi = abi
    }

    public var id: String { package }

    public var label: String {
        let apiLabel = api.hasPrefix("android-") ? "API " + api.dropFirst("android-".count) : api
        let tagLabel: String = switch tag {
        case "google_apis": "Google APIs"
        case "google_atd": "Google APIs ATD"
        case "aosp": "AOSP"
        case _ where tag.hasPrefix("google_apis_playstore_ps16k"): "Play Store · 16 KB"
        case _ where tag.hasPrefix("google_apis_ps16k"): "Google APIs · 16 KB"
        case _ where tag.hasPrefix("google_apis_playstore"): "Play Store"
        // Wear OS, TV, Automotive …: the plain words, not the package tag
        // ("android-wear-signed" read in the create sheet).
        default: variantTitle
        }
        return "\(apiLabel) · \(tagLabel) · \(abi)"
    }

    /// The image in plain words for the app's Settings window, with no
    /// package id: "Android 15 · Google Play · arm64". An API level with no
    /// known Android release keeps "API <level>".
    public var friendlyLabel: String {
        let level = api.hasPrefix("android-") ? String(api.dropFirst("android-".count)) : api
        let release = Self.androidRelease(forAPILevel: level)
        let versionLabel = release.map { "Android \($0)" } ?? "API \(level)"
        let flavour: String = switch tag {
        case "google_apis": "Google APIs"
        case "google_atd", "google_atd_ps16k": "Automated test device"
        case "aosp", "aosp_atd": "AOSP"
        case _ where tag.hasPrefix("google_apis_playstore_ps16k"): "Google Play (16 KB pages)"
        case _ where tag.hasPrefix("google_apis_ps16k"): "Google APIs (16 KB pages)"
        case _ where tag.hasPrefix("google_apis_playstore"): "Google Play"
        default: variantTitle
        }
        let processor: String = switch abi {
        case "arm64-v8a": "arm64"
        case "armeabi-v7a": "arm"
        default: abi
        }
        return "\(versionLabel) · \(flavour) · \(processor)"
    }
}

/// Parses `avdmanager` output.
public enum AvdmanagerParsing {
    /// Parses `avdmanager list device`:
    ///
    ///     id: 0 or "pixel_9_pro"
    ///         Name: Pixel 9 Pro
    ///         OEM : Google
    public static func devices(from output: String) -> [AvdDevice] {
        var devices: [AvdDevice] = []
        var pendingID: String?
        var pendingName: String?
        var pendingTag: String?

        func flush() {
            if let id = pendingID {
                devices.append(AvdDevice(id: id, name: pendingName ?? id, tag: pendingTag))
            }
            pendingID = nil
            pendingName = nil
            pendingTag = nil
        }

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let id = deviceID(from: line) {
                flush()
                pendingID = id
            } else if pendingID != nil, let separator = line.firstIndex(of: ":") {
                let key = line[..<separator].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                if key == "Name", pendingName == nil, !value.isEmpty {
                    pendingName = value
                } else if key == "Tag", pendingTag == nil, !value.isEmpty {
                    pendingTag = value
                }
            }
        }
        flush()
        return devices
    }

    private static func deviceID(from line: String) -> String? {
        // id: 0 or "pixel_9_pro"
        guard line.hasPrefix("id:") else { return nil }
        guard let firstQuote = line.firstIndex(of: "\""),
              let lastQuote = line.lastIndex(of: "\""),
              firstQuote != lastQuote
        else {
            return nil
        }
        let id = String(line[line.index(after: firstQuote)..<lastQuote])
        return id.isEmpty ? nil : id
    }
}

/// Creates AVDs through the SDK's `avdmanager` (requires Java).
public final class AvdmanagerClient: Sendable {
    public let avdmanagerURL: URL
    private let javaURL: URL?
    /// Bounds for the two commands: `list device` only reads local files (a JVM
    /// start), `create avd` may unpack a system image. A hung tool ends with
    /// `AvdmanagerError.commandFailed` instead of leaving the UI waiting.
    private let listTimeout: Duration
    private let createTimeout: Duration

    public init(
        avdmanagerURL: URL,
        javaURL: URL? = nil,
        listTimeout: Duration = .seconds(60),
        createTimeout: Duration = .seconds(180)
    ) {
        self.avdmanagerURL = avdmanagerURL
        self.javaURL = javaURL
        self.listTimeout = listTimeout
        self.createTimeout = createTimeout
    }

    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AvdmanagerClient? {
        guard let avdmanagerURL = AvdmanagerLocator.locate(environment: environment) else {
            return nil
        }
        return AvdmanagerClient(avdmanagerURL: avdmanagerURL)
    }

    /// Environment for `avdmanager` invocations: points `JAVA_HOME` at the
    /// working runtime, since the script cannot find runtimes that are
    /// installed but not on the PATH (like Homebrew's keg-only OpenJDK).
    private func avdmanagerEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> [String: String] {
        guard let resolved = await AvdmanagerLocator.javaHomeEnvironment(
            environment: environment,
            preferred: javaURL
        ) else {
            throw AvdmanagerError.javaNotFound
        }
        return resolved
    }

    /// The first Java that actually runs, or nil when there is no runtime.
    public func workingJava(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> URL? {
        await AvdmanagerLocator.workingJava(environment: environment, preferred: javaURL)
    }

    public func listDevices() async throws -> [AvdDevice] {
        let environment = try await avdmanagerEnvironment()
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: avdmanagerURL,
                arguments: ["list", "device"],
                environment: environment,
                timeout: listTimeout
            )
        } catch let error as ProcessRunnerError {
            throw AvdmanagerError.commandFailed("avdmanager list device: \(error)")
        }
        guard result.exitCode == 0 else {
            throw AvdmanagerError.commandFailed(
                "avdmanager list device failed:\n\(result.standardErrorText)"
            )
        }
        return AvdmanagerParsing.devices(from: result.standardOutputText)
    }

    /// Creates an AVD, answering "no" to the custom-hardware-profile prompt.
    ///
    /// Never overwrites: a name that already exists in the AVD home — compared
    /// case-insensitively, like the volume compares it — throws
    /// `AvdmanagerError.avdAlreadyExists` before avdmanager runs, and
    /// avdmanager itself runs without `-f` (which would wipe the existing
    /// AVD's user data and snapshots) so a name created in the meantime is
    /// refused too. `avdHome` defaults to `AvdHome.url()`; when given it is
    /// also where avdmanager creates the AVD (`ANDROID_AVD_HOME`).
    public func createAvd(
        name: String,
        deviceId: String,
        systemImage: String,
        avdHome: URL? = nil
    ) async throws {
        let home = avdHome ?? AvdHome.url()
        guard !AvdHome.containsAvd(named: name, in: home) else {
            throw AvdmanagerError.avdAlreadyExists(name)
        }
        var environment = try await avdmanagerEnvironment()
        if let avdHome {
            environment["ANDROID_AVD_HOME"] = avdHome.path
        }
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: avdmanagerURL,
                arguments: [
                    "create", "avd",
                    "-n", name,
                    "-k", systemImage,
                    "-d", deviceId,
                ],
                standardInput: Data("no\n".utf8),
                environment: environment,
                timeout: createTimeout
            )
        } catch let error as ProcessRunnerError {
            throw AvdmanagerError.commandFailed("avdmanager create avd: \(error)")
        }
        guard result.exitCode == 0 else {
            let detail = [result.standardOutputText, result.standardErrorText]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // avdmanager's own refusal suggests `--force`, which is exactly
            // what must not happen: report it as the name clash it is.
            if detail.localizedCaseInsensitiveContains("already exists") {
                throw AvdmanagerError.avdAlreadyExists(name)
            }
            throw AvdmanagerError.commandFailed(
                detail.isEmpty ? "avdmanager create avd failed." : detail
            )
        }
    }

    /// System images installed under the SDK's `system-images` directory.
    /// Scanned from disk, so it works without Java.
    public static func installedSystemImages(sdkRoot: URL) -> [SystemImage] {
        let manager = FileManager.default
        let root = sdkRoot.appendingPathComponent("system-images", isDirectory: true)
        let apis = ((try? manager.contentsOfDirectory(atPath: root.path)) ?? []).sorted()

        var images: [SystemImage] = []
        for api in apis {
            let apiURL = root.appendingPathComponent(api, isDirectory: true)
            let tags = ((try? manager.contentsOfDirectory(atPath: apiURL.path)) ?? []).sorted()
            for tag in tags {
                let tagURL = apiURL.appendingPathComponent(tag, isDirectory: true)
                let abis = ((try? manager.contentsOfDirectory(atPath: tagURL.path)) ?? []).sorted()
                for abi in abis {
                    var isDirectory: ObjCBool = false
                    guard manager.fileExists(
                        atPath: tagURL.appendingPathComponent(abi).path,
                        isDirectory: &isDirectory
                    ), isDirectory.boolValue else {
                        continue
                    }
                    images.append(
                        SystemImage(
                            package: "system-images;\(api);\(tag);\(abi)",
                            api: api,
                            tag: tag,
                            abi: abi
                        )
                    )
                }
            }
        }
        return images.sorted {
            if $0.api != $1.api { return $0.api > $1.api }
            if $0.tag != $1.tag { return $0.tag < $1.tag }
            return $0.abi < $1.abi
        }
    }

    /// The Android SDK root: `ANDROID_HOME` / `ANDROID_SDK_ROOT`, else the
    /// root the located `avdmanager` or `adb` belongs to, else
    /// `~/Library/Android/sdk`.
    ///
    /// Tool-derived roots resolve symlinks first — Homebrew's
    /// `/opt/homebrew/bin/avdmanager` stripped as-is gives `/`, and its `adb`
    /// gives `/opt` — and count only when the directory looks like an SDK
    /// (see `looksLikeSdkRoot`): a platform-tools-only cask directory is not
    /// one, and would hide the real SDK's system images.
    public static func sdkRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        // (path, must look like an SDK): explicit roots are taken at their word.
        var candidates: [(path: String, needsMarkers: Bool)] = []
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = environment[key], !root.isEmpty {
                candidates.append((root, false))
            }
        }
        if let avdmanager = AvdmanagerLocator.locate(environment: environment) {
            // .../cmdline-tools/<rev>/bin/avdmanager → SDK root.
            candidates.append((
                avdmanager.resolvingSymlinksInPath()
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent().path,
                true
            ))
        }
        if let adb = AdbBinaryLocator.locate(environment: environment) {
            // .../platform-tools/adb → SDK root.
            candidates.append((
                adb.resolvingSymlinksInPath()
                    .deletingLastPathComponent().deletingLastPathComponent().path,
                true
            ))
        }
        candidates.append((
            FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Android/sdk",
            false
        ))

        let manager = FileManager.default
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(
                atPath: candidate.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                continue
            }
            let url = URL(fileURLWithPath: candidate.path, isDirectory: true)
            if candidate.needsMarkers, !looksLikeSdkRoot(url) {
                continue
            }
            return url
        }
        return nil
    }

    /// Whether `url` holds SDK content beyond platform-tools: system images,
    /// command-line tools, the emulator, platforms, build tools or licenses.
    static func looksLikeSdkRoot(_ url: URL) -> Bool {
        let manager = FileManager.default
        return ["system-images", "cmdline-tools", "emulator", "platforms", "build-tools", "licenses"]
            .contains { manager.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    /// Matches a catalog skin to its `-d` device id: exact match first, then
    /// a normalized match (`Galaxy Nexus` → `galaxy_nexus`, verified against
    /// the live `list device` output), then explicit aliases.
    public static func device(forSkinName skin: String, devices: [AvdDevice]) -> AvdDevice? {
        if let exact = devices.first(where: { $0.id == skin }) {
            return exact
        }
        let wanted = normalize(skin)
        if let fuzzy = devices.first(where: { normalize($0.id) == wanted }) {
            return fuzzy
        }
        if let alias = skinAliases[skin] {
            return devices.first(where: { $0.id == alias })
        }
        return nil
    }

    private static func normalize(_ id: String) -> String {
        id.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    /// Skins whose name matches no device definition even normalized
    /// (verified against the device XMLs bundled in cmdline-tools).
    private static let skinAliases = [
        "pixel_silver": "pixel",
        "pixel_xl_silver": "pixel_xl",
        "automotive_landscape": "automotive_1080p_landscape",
        "automotive_ultrawide_cutout": "automotive_ultrawide",
    ]

    /// AVD names allow letters, digits and `._-`; anything else breaks creation.
    public static func sanitizedAvdName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(
            of: "[^A-Za-z0-9._-]+",
            with: "_",
            options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        return cleaned.isEmpty ? "device" : cleaned
    }
}
