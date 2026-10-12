import Darwin
import Foundation

// The Android side of a collection that needs no process: the environment,
// the SDK folders, the tools in them, the console token file and the AVDs.
// Files are listed and read, never written: nothing here calls the target
// repair, the display repair or any file operation that writes.

extension CollectionRun {
    // MARK: Environment

    /// The environment variables the Android tools read, those that are set.
    /// A value is kept only for `ADB_MDNS` and an all-digits
    /// `ANDROID_ADB_SERVER_PORT`; the path-valued ones say whether the path
    /// exists.
    func variables() -> [ProblemReport.Variable] {
        let pathValued: Set<String> = [
            "ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_AVD_HOME", "ANDROID_EMULATOR_HOME",
            "ANDROID_USER_HOME", "ANDROID_PREFS_ROOT", "ANDROID_SDK_HOME", "JAVA_HOME",
        ]
        let names = [
            "ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_AVD_HOME", "ANDROID_EMULATOR_HOME",
            "ANDROID_USER_HOME", "ANDROID_PREFS_ROOT", "ANDROID_SDK_HOME", "ANDROID_ADB_SERVER_PORT",
            "ADB_MDNS", "ADB_SERVER_SOCKET", "JAVA_HOME",
        ]
        return names.compactMap { name in
            guard let value = environment[name] else { return nil }
            var kept: String?
            if name == "ADB_MDNS" {
                kept = value
            } else if name == "ANDROID_ADB_SERVER_PORT", !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isWholeNumber }) {
                kept = value
            }
            let exists = pathValued.contains(name) && !value.isEmpty
                ? FileManager.default.fileExists(atPath: (value as NSString).expandingTildeInPath)
                : nil
            return ProblemReport.Variable(name: name, value: kept, pathExists: exists)
        }
    }

    // MARK: SDK folders

    struct SdkRoots {
        var reports: [ProblemReport.SdkRoot]
        var paths: [String]
    }

    /// The Revision a package's `source.properties` states.
    func revision(inPropertiesAt url: URL) -> String? {
        let value = AvdConfig.valuesFile(url)["Pkg.Revision"]?.trimmingCharacters(in: .whitespaces)
        return value?.isEmpty == false ? value : nil
    }

    /// The SDK folders, worked out from the injected environment and home (not
    /// `AvdmanagerLocator.sdkRoots`, which reads the real home), in the order
    /// the locators try them and without repeats: `ANDROID_HOME`,
    /// `ANDROID_SDK_ROOT`, Android Studio's default, the SDK the adb is in and
    /// the one the emulator is in.
    func sdkRoots() -> SdkRoots {
        var ordered: [(path: String, foundBy: String)] = []
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let value = environment[key], !value.isEmpty { ordered.append((value, key)) }
        }
        ordered.append((home.path + "/Library/Android/sdk", "default"))
        func root(of executable: URL) -> String {
            executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().path
        }
        if let adb = inputs.adbURL { ordered.append((root(of: adb), "adb")) }
        if let emulator = inputs.emulatorURL { ordered.append((root(of: emulator), "emulator")) }

        // One entry per folder (a link and its target are one), shown as first found.
        var paths: [String] = []
        var foundBy: [String: [String]] = [:]
        var shown: [String: String] = [:]
        for entry in ordered {
            let resolved = URL(fileURLWithPath: entry.path).resolvingSymlinksInPath().path
            let key = shown[resolved] ?? URL(fileURLWithPath: entry.path).standardizedFileURL.path
            if shown[resolved] == nil {
                shown[resolved] = key
                paths.append(key)
            }
            if !(foundBy[key] ?? []).contains(entry.foundBy) { foundBy[key, default: []].append(entry.foundBy) }
        }
        return SdkRoots(
            reports: paths.map { sdkRootReport(path: $0, foundBy: foundBy[$0] ?? []) },
            paths: paths
        )
    }

    private func sdkRootReport(path: String, foundBy: [String]) -> ProblemReport.SdkRoot {
        let manager = FileManager.default
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard manager.fileExists(atPath: path) else {
            return ProblemReport.SdkRoot(path: path, foundBy: foundBy, exists: false)
        }
        let emulatorFolder = url.appendingPathComponent("emulator", isDirectory: true)
        let emulatorVersion = revision(inPropertiesAt: emulatorFolder.appendingPathComponent("source.properties"))
            ?? EmulatorVersion.installedVersion(emulatorBinary: emulatorFolder.appendingPathComponent("emulator"))

        let toolsFolder = url.appendingPathComponent("cmdline-tools", isDirectory: true)
        let folders = ((try? manager.contentsOfDirectory(atPath: toolsFolder.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted { lhs, rhs in
                if lhs == "latest" { return rhs != "latest" }
                if rhs == "latest" { return false }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        let cmdlineTools = folders.map { folder in
            ProblemReport.CmdlineTools(
                folder: folder,
                version: revision(inPropertiesAt: toolsFolder.appendingPathComponent("\(folder)/source.properties"))
            )
        }

        return ProblemReport.SdkRoot(
            path: path,
            foundBy: foundBy,
            exists: true,
            platformTools: revision(inPropertiesAt: url.appendingPathComponent("platform-tools/source.properties")),
            emulator: emulatorVersion,
            cmdlineTools: cmdlineTools,
            systemImages: systemImageCount(in: url.appendingPathComponent("system-images", isDirectory: true))
        )
    }

    /// The `system-images/<api>/<tag>/<abi>` folders; nil without a
    /// `system-images` folder.
    private func systemImageCount(in folder: URL) -> Int? {
        let manager = FileManager.default
        guard let apis = try? manager.contentsOfDirectory(atPath: folder.path) else { return nil }
        var count = 0
        for api in apis where !api.hasPrefix(".") {
            let apiFolder = folder.appendingPathComponent(api, isDirectory: true)
            for tag in (try? manager.contentsOfDirectory(atPath: apiFolder.path)) ?? [] where !tag.hasPrefix(".") {
                let tagFolder = apiFolder.appendingPathComponent(tag, isDirectory: true)
                for abi in (try? manager.contentsOfDirectory(atPath: tagFolder.path)) ?? [] where !abi.hasPrefix(".") {
                    var isDirectory: ObjCBool = false
                    if manager.fileExists(atPath: tagFolder.appendingPathComponent(abi).path, isDirectory: &isDirectory),
                       isDirectory.boolValue {
                        count += 1
                    }
                }
            }
        }
        return count
    }

    // MARK: Tools

    /// The adb Device Hub Pro uses, its revision (from the `source.properties`
    /// beside the real file, so a Homebrew cask's link counts) and the other
    /// adb executables the locators would also find.
    func adbInfo() -> ProblemReport.AdbInfo {
        guard let adbURL = inputs.adbURL else {
            return ProblemReport.AdbInfo(otherCopies: otherAdbCopies(besides: nil))
        }
        return ProblemReport.AdbInfo(
            path: adbURL.path,
            version: toolRevision(of: adbURL),
            otherCopies: otherAdbCopies(besides: adbURL)
        )
    }

    /// The revision of the package a tool executable belongs to.
    func toolRevision(of executable: URL) -> String? {
        let folder = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        return revision(inPropertiesAt: folder.appendingPathComponent("source.properties"))
    }

    private func otherAdbCopies(besides adbURL: URL?) -> [ProblemReport.OtherAdb] {
        let manager = FileManager.default
        let candidates = AdbBinaryLocator.candidates(
            environment: environment,
            homeDirectory: home,
            fixed: inputs.fixedAdbCandidates
        )
        var seen = Set<String>()
        if let adbURL { seen.insert(adbURL.resolvingSymlinksInPath().path) }
        var others: [ProblemReport.OtherAdb] = []
        for candidate in candidates where manager.isExecutableFile(atPath: candidate) {
            let url = URL(fileURLWithPath: candidate)
            guard seen.insert(url.resolvingSymlinksInPath().path).inserted else { continue }
            others.append(ProblemReport.OtherAdb(path: candidate, version: toolRevision(of: url)))
        }
        return others
    }

    /// The emulator binary in use and its package's revision and build.
    func emulatorInfo() -> ProblemReport.ToolInfo? {
        guard let url = inputs.emulatorURL else { return nil }
        let real = url.resolvingSymlinksInPath()
        let properties = AvdConfig.valuesFile(
            real.deletingLastPathComponent().appendingPathComponent("source.properties")
        )
        let version = revision(inPropertiesAt: real.deletingLastPathComponent().appendingPathComponent("source.properties"))
            ?? EmulatorVersion.installedVersion(emulatorBinary: real)
        return ProblemReport.ToolInfo(path: url.path, version: version, build: properties["Pkg.BuildId"])
    }

    /// The avdmanager Device Hub Pro would run: the first executable of the
    /// locator's candidates, and the revision of the cmdline-tools folder it
    /// is in. Nothing is run (no Java either).
    func avdmanagerInfo(roots: SdkRoots) -> ProblemReport.ToolInfo? {
        let candidates = AvdmanagerLocator.candidates(tool: "avdmanager", environment: environment, sdkRoots: roots.paths)
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        // `<sdk>/cmdline-tools/<folder>/bin/avdmanager`.
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
        var version: String?
        if folder.deletingLastPathComponent().lastPathComponent == "cmdline-tools" {
            version = revision(inPropertiesAt: folder.appendingPathComponent("source.properties"))
        }
        return ProblemReport.ToolInfo(path: path, version: version)
    }

    // MARK: Token file

    /// The state of a console token file. Its bytes are read only to tell a
    /// blank file (whitespace only, at most 4096 bytes) from a filled one, and
    /// are discarded in the function: never stored, hashed or logged.
    func tokenFile(at url: URL) -> ProblemReport.TokenFileInfo {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            let missing = errno == ENOENT || errno == ENOTDIR
            return ProblemReport.TokenFileInfo(path: url.path, state: missing ? .missing : .unreadable)
        }
        let size = Int(info.st_size)
        let mode = String(format: "%03o", UInt32(info.st_mode & 0o777))
        let owned = info.st_uid == getuid()
        guard (info.st_mode & 0o170000) == 0o100000 else {
            return ProblemReport.TokenFileInfo(path: url.path, state: .notAFile, bytes: size, mode: mode, ownedByUser: owned)
        }
        var state = ProblemReport.TokenState.present
        if size == 0 {
            state = .empty
        } else if size <= 4096 {
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                return ProblemReport.TokenFileInfo(path: url.path, state: .unreadable, bytes: size, mode: mode, ownedByUser: owned)
            }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 4096) else {
                return ProblemReport.TokenFileInfo(path: url.path, state: .unreadable, bytes: size, mode: mode, ownedByUser: owned)
            }
            if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D].contains($0) }) { state = .blank }
        }
        return ProblemReport.TokenFileInfo(path: url.path, state: state, bytes: size, mode: mode, ownedByUser: owned)
    }

    // MARK: AVDs

    struct AvdHomeFacts {
        let url: URL
        let appURL: URL

        func report(avdCount: Int) -> ProblemReport.AvdHomeInfo {
            ProblemReport.AvdHomeInfo(
                path: url.path,
                exists: FileManager.default.fileExists(atPath: url.path),
                appPath: appURL.standardizedFileURL.path == url.standardizedFileURL.path ? nil : appURL.path,
                avdCount: avdCount
            )
        }
    }

    /// The AVD home the emulator resolves and, to show a difference, the one
    /// Device Hub Pro's own file operations resolve.
    func avdHome() -> AvdHomeFacts {
        AvdHomeFacts(
            url: AvdHome.url(environment: environment, homeDirectory: home),
            appURL: AvdConfig.defaultHomeURL(environment: environment, userHome: home)
        )
    }

    struct AvdSet {
        var avds: [ProblemReport.Avd]
        /// How many AVDs the home holds.
        var total: Int
    }

    static let maxAvds = 30

    /// At most 30 AVDs: running ones first, then the newest `config.ini`.
    func avds(home avdHome: URL, roots: SdkRoots, running: Set<String>, hostIsAppleSilicon: Bool) -> AvdSet {
        let names = AvdHome.avdNames(in: avdHome)
        let manager = FileManager.default
        let ordered = names.map { name -> (name: String, modified: Date) in
            let config = AvdConfig.configURL(avdName: name, avdHome: avdHome)
            let date = (try? manager.attributesOfItem(atPath: config.path))?[.modificationDate] as? Date
            return (name, date ?? .distantPast)
        }.sorted { lhs, rhs in
            let lhsRunning = running.contains(lhs.name)
            if lhsRunning != running.contains(rhs.name) { return lhsRunning }
            return lhs.modified > rhs.modified
        }
        let sdkRoots = roots.paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let listed = appState?.emulatorListAvds.map(Set.init)
        let avds = ordered.prefix(Self.maxAvds).map { entry in
            avdReport(
                name: entry.name,
                home: avdHome,
                sdkRoots: sdkRoots,
                running: running.contains(entry.name),
                listed: listed.map { $0.contains(entry.name) },
                hostIsAppleSilicon: hostIsAppleSilicon
            )
        }
        return AvdSet(avds: avds, total: names.count)
    }

    private func avdReport(
        name: String,
        home avdHome: URL,
        sdkRoots: [URL],
        running: Bool,
        listed: Bool?,
        hostIsAppleSilicon: Bool
    ) -> ProblemReport.Avd {
        let manager = FileManager.default
        let config = AvdConfig.values(avdName: name, avdHome: avdHome)
        let pointer = AvdConfig.valuesFile(avdHome.appendingPathComponent("\(name).ini"))
        func text(_ values: [String: String], _ key: String) -> String? {
            let value = values[key]?.trimmingCharacters(in: .whitespaces)
            return value?.isEmpty == false ? value : nil
        }

        let sysdir = text(config, "image.sysdir.1")
        var imageAPI: String?
        var image = ProblemReport.ImageState.unnamed
        if sysdir != nil {
            let directory = EmulatorPreflight.systemImageDirectory(avdName: name, avdHome: avdHome, sdkRoots: sdkRoots)
            var isDirectory: ObjCBool = false
            if let directory, manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue {
                imageAPI = EmulatorPreflight.apiLevel(ofImage: directory)
                // The image check alone, whatever this Mac's processor.
                let problem = EmulatorPreflight.problem(
                    avdName: name, avdHome: avdHome, sdkRoots: sdkRoots, hostIsAppleSilicon: false
                )
                image = problem == EmulatorStartFailure.missingSystemImage ? .incomplete : .ok
            } else {
                image = .missing
            }
        }

        let content = AvdConfig.contentDirectory(avdName: name, avdHome: avdHome)
        let contentFolder = contentFolderState(pointer: pointer, name: name, home: avdHome)
        let lockFiles = ((try? manager.contentsOfDirectory(atPath: content.path)) ?? [])
            .filter { $0.hasSuffix(".lock") }
            .sorted()

        return ProblemReport.Avd(
            name: name,
            target: text(pointer, "target"),
            configTarget: text(config, "target"),
            imageSysdir: sysdir,
            imageAPI: imageAPI,
            abi: text(config, "abi.type"),
            tag: text(config, "tag.id"),
            device: text(config, "hw.device.name"),
            playStore: text(config, "PlayStore.enabled").flatMap { EmulatorIni.boolean($0) },
            ramMB: text(config, "hw.ramSize").flatMap(Self.megabytes),
            image: image,
            preflightProblem: EmulatorPreflight.problem(
                avdName: name, avdHome: avdHome, sdkRoots: sdkRoots, hostIsAppleSilicon: hostIsAppleSilicon
            ),
            contentFolder: contentFolder,
            quickBootSnapshot: manager.fileExists(atPath: content.appendingPathComponent("snapshots/default_boot").path),
            lockFiles: lockFiles,
            running: running,
            listedByEmulator: listed
        )
    }

    /// Where the AVD's data lives, from its registry entry the way
    /// `AvdConfig.contentDirectory` reads it, but without the fallback: an
    /// entry that names a folder with no `config.ini` is `missing` (the
    /// emulator cannot start it), not the default folder.
    private func contentFolderState(pointer: [String: String], name: String, home avdHome: URL) -> ProblemReport.ContentFolder {
        let manager = FileManager.default
        var declared: [URL] = []
        if let path = pointer["path"], path.hasPrefix("/") {
            declared.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        if let relative = pointer["path.rel"], !relative.isEmpty, !relative.hasPrefix("/") {
            declared.append(avdHome.deletingLastPathComponent().appendingPathComponent(relative, isDirectory: true))
        }
        if declared.isEmpty {
            declared.append(avdHome.appendingPathComponent("\(name).avd", isDirectory: true))
        }
        guard let found = declared.first(where: {
            manager.fileExists(atPath: $0.appendingPathComponent("config.ini").path)
        }) else { return .missing }
        let homePath = avdHome.resolvingSymlinksInPath().path
        return found.resolvingSymlinksInPath().path.hasPrefix(homePath + "/") ? .inHome : .external
    }

    /// "1536M", "2048", "4096MB" or "4G" in megabytes.
    static func megabytes(_ text: String) -> Int? {
        let pattern = "^\\s*([0-9]+)\\s*([MmGg])?[Bb]?\\s*$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let number = Range(match.range(at: 1), in: text).flatMap({ Int(text[$0]) })
        else { return nil }
        if let unit = Range(match.range(at: 2), in: text), text[unit].lowercased() == "g" { return number * 1024 }
        return number
    }

    // MARK: The app's own adb view

    func appAdbState() -> ProblemReport.AppAdbState? {
        guard let state = appState else { return nil }
        return ProblemReport.AppAdbState(
            adbAvailable: state.adbAvailable,
            serverProblem: state.adbServerProblem,
            watcherDegraded: state.watcherDegraded,
            localNetwork: state.localNetworkAccess,
            adbRestarts: state.adbRestarts,
            consoleNames: state.consoleNames.sorted { $0.key < $1.key }.map { "\($0.key) \u{2192} \($0.value)" },
            startingAvds: state.startingAvds
        )
    }
}
