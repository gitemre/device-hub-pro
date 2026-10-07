import XCTest

/// Source scans over the production Apple code (`Sources/DeviceHubProKit/Apple`,
/// and the app's and the bridge's Apple folders once they exist). They pin
/// the rules no fake can: production code never names an implicit simulator
/// selector (`booted`, `all`, …), never enumerates or manages devices through
/// devicectl, never runs the `xcrun` wrappers, and never loads a framework in
/// the Kit. The only lines allowed to spell a refused word are the refusal
/// lists themselves, marked `// source-guard: refusal list`; the one
/// exception is `devicectl list devices`, which only
/// `ApplePhysicalDeviceLister` may spell (behind its opt-in).
final class AppleSourceGuardTests: XCTestCase {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let scannedFolders = [
        "Sources/DeviceHubProKit/Apple",
        "Sources/DeviceHubProApp/Apple",
        "Sources/DeviceHubProSimBridge",
    ]

    private static let marker = "// source-guard: refusal list"

    /// The only file that may run `devicectl list devices`.
    private static let listerFile = "Sources/DeviceHubProKit/Apple/ApplePhysicalDeviceLister.swift"

    private struct SourceLine {
        let file: String
        let number: Int
        let text: String
    }

    /// Every non-comment line of every scanned Swift / Objective-C file.
    private static func codeLines() throws -> [SourceLine] {
        var lines: [SourceLine] = []
        let fileManager = FileManager.default
        for folder in scannedFolders {
            let root = repositoryRoot.appendingPathComponent(folder, isDirectory: true)
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where ["swift", "m", "h"].contains(url.pathExtension) {
                let text = try String(contentsOf: url, encoding: .utf8)
                let relative = String(url.path.dropFirst(repositoryRoot.path.count + 1))
                for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
                    lines.append(SourceLine(file: relative, number: index + 1, text: String(line)))
                }
            }
        }
        return lines
    }

    /// The string literals on one line (no multi-line literals in the scanned code).
    private static func literals(in line: String) -> [String] {
        var literals: [String] = []
        var current: String?
        var escaped = false
        for character in line {
            if var open = current {
                if escaped {
                    escaped = false
                    open.append(character)
                    current = open
                } else if character == "\\" {
                    escaped = true
                    open.append(character)
                    current = open
                } else if character == "\"" {
                    literals.append(open)
                    current = nil
                } else {
                    open.append(character)
                    current = open
                }
            } else if character == "\"" {
                current = ""
            }
        }
        return literals
    }

    func testTheScanSeesTheAppleKit() throws {
        let files = Set(try Self.codeLines().map(\.file))
        XCTAssertTrue(files.contains("Sources/DeviceHubProKit/Apple/SimctlClient.swift"), "\(files)")
        XCTAssertTrue(files.contains("Sources/DeviceHubProKit/Apple/DevicectlClient.swift"), "\(files)")
        XCTAssertTrue(files.contains("Sources/DeviceHubProApp/Apple/SimulatorLifecycleController.swift"), "\(files)")
    }

    /// Whether a string literal is an implicit selector: `booted`,
    /// `booted_*`, `all` or `unavailable` as the whole literal, the way an
    /// argv element carries it. Prose that uses the word ("…, not booted",
    /// the bridge's error text) selects nothing and passes. Selectors are
    /// lowercase; the capitalised state name simctl prints ("Booted") is not
    /// one.
    static func isImplicitSelector(_ literal: String) -> Bool {
        let token = literal.trimmingCharacters(in: .whitespaces)
        if ["booted", "all", "unavailable"].contains(token) { return true }
        return token.hasPrefix("booted_") && !token.contains(where: \.isWhitespace)
    }

    func testTheSelectorRuleMatchesWholeLiteralsOnly() {
        for literal in ["booted", "all", "unavailable", "booted_phone", " booted "] {
            XCTAssertTrue(Self.isImplicitSelector(literal), literal)
        }
        for literal in ["Booted", "not booted", "simulator %@ is %@, not booted", "all devices", "install"] {
            XCTAssertFalse(Self.isImplicitSelector(literal), literal)
        }
    }

    /// No string literal is an implicit selector, except on the refusal list
    /// itself.
    func testNoImplicitSimulatorSelectors() throws {
        var offenders: [String] = []
        for line in try Self.codeLines() where !line.text.contains(Self.marker) {
            if Self.literals(in: line.text).contains(where: Self.isImplicitSelector) {
                offenders.append("\(line.file):\(line.number): \(line.text.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(offenders, [], "implicit selectors in production Apple code")
    }

    /// The refusal lists are where the scan expects them, and only there.
    func testRefusalListsAreMarkedOnlyInTheClients() throws {
        let marked = try Self.codeLines().filter { $0.text.contains(Self.marker) }
        XCTAssertEqual(Set(marked.map(\.file)), [
            "Sources/DeviceHubProKit/Apple/SimctlClient.swift",
            "Sources/DeviceHubProKit/Apple/DevicectlClient.swift",
            "Sources/DeviceHubProKit/Apple/DevicectlPhysicalClient.swift",
        ])
        XCTAssertEqual(marked.count, 3)
        XCTAssertTrue(marked.allSatisfy { $0.text.contains("static let refused") })
    }

    /// Whether a line spells `devicectl list devices` in code.
    private static func spellsListDevices(_ text: String) -> Bool {
        text.contains("\"list\", \"devices\"") || literals(in: text).joined(separator: " ").contains("list devices")
    }

    /// devicectl never enumerates (`list devices`) or manages devices,
    /// except that the physical-device lister, alone, may list.
    func testNoDeviceEnumerationOrManagement() throws {
        var offenders: [String] = []
        for line in try Self.codeLines() where !line.text.contains(Self.marker) && !line.text.contains(Self.allowMarker) {
            let text = line.text
            let listsDevices = Self.spellsListDevices(text) && line.file != Self.listerFile
            if listsDevices || Self.literals(in: text).contains("manage") {
                offenders.append("\(line.file):\(line.number): \(text.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(offenders, [])
    }

    /// The `xcrun` wrappers are never run: no `xcrun` anywhere, and the
    /// wrapper paths appear only in `AppleToolchain`, which reads them as text.
    func testNoXcrunWrapper() throws {
        var offenders: [String] = []
        for line in try Self.codeLines() {
            let text = line.text
            if text.contains("xcrun") {
                offenders.append("\(line.file):\(line.number): \(text.trimmingCharacters(in: .whitespaces))")
            }
            if (text.contains("usr/bin/simctl") || text.contains("usr/bin/devicectl")),
               line.file != "Sources/DeviceHubProKit/Apple/AppleToolchain.swift" {
                offenders.append("\(line.file):\(line.number): \(text.trimmingCharacters(in: .whitespaces))")
            }
            if text.contains("-runFirstLaunch") {
                offenders.append("\(line.file):\(line.number): \(text.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(offenders, [])
    }

    /// `list devices` is spelled in the lister's file, and nowhere else.
    func testListDevicesIsSpelledOnlyInTheLister() throws {
        let files = Set(try Self.codeLines().filter { Self.spellsListDevices($0.text) }.map(\.file))
        XCTAssertEqual(files, [Self.listerFile])
    }

    private static let physicalClientFile = "Sources/DeviceHubProKit/Apple/DevicectlPhysicalClient.swift"
    /// The client's Controls extension: it builds no subcommand of its own
    /// (it uses `DevicectlPhysicalControl.words`), so it is scanned for the
    /// same words and carries no allow-list line.
    private static let physicalControlsFile = "Sources/DeviceHubProKit/Apple/DevicectlPhysicalClient+Controls.swift"
    private static let allowMarker = "// source-guard: allow list"

    /// The physical client runs exactly the allow-list: every subcommand word
    /// that writes to, changes, simulates or reads files from the phone
    /// (install, launch, screenshot, copy, settings, simulate, orientation,
    /// pasteboard ...) is spelled only on the marked lines of
    /// `DevicectlPhysicalAction.words` and `DevicectlPhysicalControl.words`,
    /// one line per command, and those lines are exactly the twenty-five. Outside
    /// them (and outside the refusal list) the client's files name no such
    /// word, so a new shape cannot be added without changing this test.
    func testPhysicalClientNamesOnlyTheAllowListedSubcommands() throws {
        let words: Set<String> = [
            "install", "uninstall", "launch", "terminate", "openURL", "screenshot", "screen-record",
            "copy", "from", "to", "files", "process", "capture", "reboot", "unpair", "reset", "sysdiagnose",
            "settings", "simulate", "orientation", "pasteboard", "sendMemoryWarning", "location", "coordinate",
            "clear", "paste", "get", "set", "voiceover", "appearance", "biometrics", "rotate", "monitor",
            "transfer", "sync-with-host", "motion", "notification", "appResize", "rename", "manage", "pair",
        ]
        var offenders: [String] = []
        var allowLines: [String] = []
        for line in try Self.codeLines() where line.file == Self.physicalClientFile || line.file == Self.physicalControlsFile {
            if line.text.contains(Self.marker) { continue }
            let literals = Self.literals(in: line.text)
            if line.text.contains(Self.allowMarker) {
                XCTAssertEqual(line.file, Self.physicalClientFile, "allow-list lines live in the client's own file")
                allowLines.append(literals.joined(separator: " "))
                continue
            }
            if literals.contains(where: words.contains) {
                offenders.append("\(line.file):\(line.number)")
            }
        }
        XCTAssertEqual(offenders, [])
        XCTAssertEqual(allowLines, [
            "device info files",
            "device install app",
            "device uninstall app",
            "device process launch",
            "device process terminate",
            "device process openURL",
            "device capture screenshot",
            "device capture screen-record",
            "device copy from",
            "device copy to",
            "device info appIcon",
            "device settings appearance",
            "device settings voiceover",
            "device orientation get",
            "device orientation set",
            "device simulate location coordinate",
            "device simulate location clear",
            "device process sendMemoryWarning",
            "device pasteboard copy",
            "device pasteboard paste",
            "device reboot",
            "device rename",
            "device sysdiagnose",
            "manage unpair",
            "manage pair",
        ])
    }

    /// The administrator-privileges wrapper is for
    /// `device sysdiagnose` alone: `osascript` and the words "administrator
    /// privileges" are spelled only in `DevicectlPrivilegedRunner`, and only
    /// the physical client names that type.
    func testThePrivilegedWrapperIsConfinedToSysdiagnose() throws {
        let runner = "Sources/DeviceHubProKit/Apple/DevicectlPrivilegedRunner.swift"
        var offenders: [String] = []
        var users: Set<String> = []
        for line in try Self.codeLines() {
            let literals = Self.literals(in: line.text)
            let mentions = line.text.contains("administrator privileges") || literals.contains { $0.contains("osascript") }
            if mentions, line.file != runner { offenders.append("\(line.file):\(line.number)") }
            if line.text.contains("DevicectlPrivilegedRunner"), line.file != runner { users.insert(line.file) }
        }
        XCTAssertEqual(offenders, [])
        XCTAssertEqual(users, [Self.physicalClientFile])
        let client = try String(contentsOf: Self.repositoryRoot.appendingPathComponent(Self.physicalClientFile), encoding: .utf8)
        XCTAssertEqual(client.components(separatedBy: "DevicectlPrivilegedRunner.run(").count - 1, 1, "one call site")
        XCTAssertTrue(client.contains("DevicectlPhysicalManagement.sysdiagnose.words + [\"--destination\""), "the one fixed shape")
    }

    /// The allow-list marker exists only in the physical client.
    func testTheAllowListIsMarkedOnlyInThePhysicalClient() throws {
        let files = Set(try Self.codeLines().filter { $0.text.contains(Self.allowMarker) }.map(\.file))
        XCTAssertEqual(files, [Self.physicalClientFile])
    }

    /// No other Apple code builds a physical-device action or Controls
    /// command: the two lists and the domain flags are named only in the
    /// physical client's files (the Controls extension reads its own list).
    func testNoOtherCodeBuildsPhysicalActions() throws {
        var offenders: [String] = []
        for line in try Self.codeLines() where line.file != Self.physicalClientFile {
            let control = line.text.contains("DevicectlPhysicalControl") && line.file != Self.physicalControlsFile
            if Self.literals(in: line.text).contains("--domain-type") || line.text.contains("DevicectlPhysicalAction") || control
                || (line.text.contains("DevicectlPhysicalManagement")) {
                offenders.append("\(line.file):\(line.number)")
            }
        }
        XCTAssertEqual(offenders, [])
    }

    /// The console launch of the physical iPhone's log pane is built and run by three places only: the client's own
    /// extension (`consoleCommandLine`), the stream that runs it
    /// (`PhysicalConsoleLogStream`) and the log pane's controller, which is the
    /// stream's one user. `--console` is spelled only in the extension.
    func testTheConsoleLaunchIsConfinedToTheLogPane() throws {
        let extensionFile = "Sources/DeviceHubProKit/Apple/DevicectlPhysicalClient+Console.swift"
        let streamFile = "Sources/DeviceHubProKit/Apple/PhysicalConsoleLogStream.swift"
        let controllerFile = "Sources/DeviceHubProApp/LogcatController+Physical.swift"
        let root = Self.repositoryRoot.appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var commandLineUsers: Set<String> = []
        var streamUsers: Set<String> = []
        var consoleFlagFiles: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(Self.repositoryRoot.path.count + 1))
            for line in try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
                if trimmed.contains("consoleCommandLine(") { commandLineUsers.insert(relative) }
                if trimmed.contains("PhysicalConsoleLogStream(") { streamUsers.insert(relative) }
                if Self.literals(in: String(line)).contains("--console") { consoleFlagFiles.insert(relative) }
            }
        }
        XCTAssertEqual(commandLineUsers, [extensionFile, streamFile])
        XCTAssertEqual(streamUsers, [controllerFile])
        XCTAssertEqual(consoleFlagFiles, [extensionFile])
    }

    /// The Kit's Apple code loads no framework (the toolchain probe reads
    /// files; only the future bridge target may `dlopen`).
    func testTheKitLoadsNoFrameworks() throws {
        let offenders = try Self.codeLines()
            .filter { $0.file.hasPrefix("Sources/DeviceHubProKit/") }
            .filter { $0.text.contains("dlopen") || $0.text.contains("dlsym") || $0.text.contains("NSClassFromString") }
            .map { "\($0.file):\($0.number)" }
        XCTAssertEqual(offenders, [])
    }

    // MARK: - The live screen of a physical iPhone

    /// The public CoreMediaIO switch that makes a connected iOS device a
    /// capture device is set in one place, the capture provider; the app
    /// calls it through the provider, and only while "Show physical Apple
    /// devices" is on (`PhysicalLiveViewControllerTests`).
    func testTheScreenCaptureSwitchIsSetOnlyInTheCaptureProvider() throws {
        let hits = try Self.codeLines()
            .filter { $0.text.contains("kCMIOHardwarePropertyAllowScreenCaptureDevices") }
            .map(\.file)
        XCTAssertEqual(Set(hits), ["Sources/DeviceHubProKit/Apple/Live/AVFoundationScreenCapture.swift"])
        XCTAssertEqual(hits.count, 1)
    }

    /// The live screen is the public capture path only: no CoreDevice media
    /// stream, no "view device screen" service, no remote input, and no
    /// tunnel of our own.
    func testNoCoreDeviceMediaStreamOrRebuiltTunnel() throws {
        let words = ["mediastream", "media-stream", "viewdevicescreen", "remotepairing", "tunnelservice", "com.apple.coredevice.feature.hid"]
        let offenders = try Self.codeLines()
            .filter { line in
                let lowered = line.text.lowercased()
                return words.contains { lowered.contains($0) } && !line.text.contains(Self.marker)
            }
            .map { "\($0.file):\($0.number)" }
        XCTAssertEqual(offenders, [])
    }

    // MARK: - Control this iPhone

    private static let launcherFile = "Sources/DeviceHubProKit/Apple/Control/PhysicalControlRunnerLauncher.swift"
    private static let liveSessionFile = "Sources/DeviceHubProKit/Apple/Control/PhysicalControlSession+Live.swift"

    /// The public-XCTest runner is started from one file: the only place
    /// that spells `xcodebuild test-without-building`.
    func testTheRunnerIsLaunchedFromOneFileOnly() throws {
        let files = try Self.codeLines()
            .filter { $0.text.contains("test-without-building") }
            .map(\.file)
        XCTAssertEqual(Set(files), [Self.launcherFile])
        XCTAssertEqual(files.count, 1)
    }

    /// Only the live factory makes the real launcher, and the app never
    /// names it: the app reaches the runner through `PhysicalControlSession`.
    func testOnlyTheLiveFactoryMakesTheRealLauncher() throws {
        let constructors = try Self.codeLines()
            .filter { $0.text.contains("XcodebuildRunnerLauncher(") }
            .map(\.file)
        XCTAssertEqual(constructors, [Self.liveSessionFile])
        let appNamesIt = try Self.codeLines()
            .filter { $0.file.hasPrefix("Sources/DeviceHubProApp/") && $0.text.contains("XcodebuildRunnerLauncher") }
        XCTAssertEqual(appNamesIt.count, 0)
    }

    /// The spike's helper endpoints (launch, probe, host, ifaddrs, screenshot)
    /// are never requested, and the runner is asked only for what
    /// `PhysicalControlRequest` builds.
    func testTheSpikesHelperEndpointsAreNeverRequested() throws {
        let offenders = try Self.codeLines()
            .filter { line in
                Self.literals(in: line.text).contains { ["/launch", "/probe", "/host", "/ifaddrs", "/screenshot"].contains($0) }
            }
            .map { "\($0.file):\($0.number)" }
        XCTAssertEqual(offenders, [])
    }

    /// No file of the physical device's code names a private remote-input or
    /// HID word (Apple's CoreDevice remote-input service, IOHID, the
    /// simulator's Indigo events): the control path is public XCTest only.
    func testNoPrivateRemoteInputOrHIDWordInThePhysicalCode() throws {
        let words = [
            "indigo", "hidevent", "iohid", "hidclient", "usagepage",
            "remoteinput", "remote-input", "coredevice.feature.hid", "coredevice.feature.remote.input",
            "coredevice.feature.remote.hid", "coredevice.feature.remote.touch", "coredevice.feature.remote.keyboard",
            "com.apple.coredevice.remote", "inputservice", "remotecontrol",
        ]
        func isPhysical(_ file: String) -> Bool {
            let name = (file as NSString).lastPathComponent
            return file.contains("/Control/") || name.hasPrefix("Physical") || name.hasPrefix("ApplePhysical")
                || name.hasPrefix("DevicectlPhysical")
        }
        let offenders = try Self.codeLines()
            .filter { isPhysical($0.file) }
            .filter { line in
                let lowered = line.text.lowercased()
                return words.contains { lowered.contains($0) } && !line.text.contains(Self.marker)
            }
            .map { "\($0.file):\($0.number)" }
        XCTAssertEqual(offenders, [])
        // The scan sees the new files.
        let files = Set(try Self.codeLines().map(\.file))
        XCTAssertTrue(files.contains(Self.launcherFile))
        XCTAssertTrue(files.contains("Sources/DeviceHubProKit/Apple/Control/PhysicalControlSession.swift"))
        XCTAssertTrue(files.contains("Sources/DeviceHubProApp/Apple/PhysicalControlController.swift"))
    }

    /// The runner's endpoint set is closed too (`/siri` and
    /// `/appSwitcher` included, both public XCTest): a new route in `ios/agent` must
    /// be listed here on purpose, and the requests the Mac builds are served
    /// by them.
    func testTheRunnersEndpointSetIsClosedAndCoversTheMacsRequests() throws {
        let actions = Self.repositoryRoot.appendingPathComponent("ios/agent/Tests/AgentActions.swift")
        let source = try String(contentsOf: actions, encoding: .utf8)
        var routes = Set<String>()
        for line in source.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case (\"GET\"") || trimmed.hasPrefix("case (\"POST\"") else { continue }
            let parts = Self.literals(in: trimmed)
            guard parts.count >= 2 else { continue }
            routes.insert("\(parts[0]) \(parts[1])")
        }
        let used: Set<String> = [
            "GET /status", "GET /screen", "GET /orientation", "GET /foreground", "POST /stop", "POST /tap",
            "POST /swipe", "POST /type", "POST /button", "POST /orientation", "POST /siri", "POST /appSwitcher",
        ]
        // The spike's helpers stay in the runner's source; the Mac never asks for them
        // (`testTheSpikesHelperEndpointsAreNeverRequested`).
        let spikeHelpers: Set<String> = [
            "GET /ifaddrs", "GET /screenshot", "POST /launch", "GET /probe", "GET /host",
        ]
        XCTAssertEqual(routes, used.union(spikeHelpers))
        // Only public XCTest reaches Siri and the App Switcher gesture.
        XCTAssertTrue(source.contains("siriService.activate(voiceRecognitionText:"))
        XCTAssertTrue(source.contains("thenDragTo: end, withVelocity: .slow, thenHoldForDuration:"))
    }

    /// The runner is never bound to anything but the tunnel: the wildcard
    /// addresses are not spelled in the control code.
    func testTheControlCodeNeverSpellsAWildcardOrLANBindAddress() throws {
        let offenders = try Self.codeLines()
            .filter { $0.file.contains("/Control/") }
            .filter { line in
                Self.literals(in: line.text).contains { ["0.0.0.0", "::", "127.0.0.1", "::1", "localhost"].contains($0) }
            }
            .map { "\($0.file):\($0.number)" }
        XCTAssertEqual(offenders, [])
    }
}
