import Foundation

// The processes of a collection: the running emulators and the adb server from
// one `ps` listing, the discovery files, and the few adb calls
// (`ProblemReportAdbCall`) made only while an adb server of the same adb is
// already running.

extension ProblemReportCollector {
    /// One running emulator VM, from a `ps` line.
    struct ParsedEmulatorProcess: Equatable, Sendable {
        var pid: Int32
        var avd: String
        /// Allow-listed flags (see `parseEmulatorProcesses`).
        var flags: [String]
        var grpcPort: Int?
        var consolePort: Int?
    }

    /// The flags whose value is kept: none can carry a path or a secret.
    private static let valueFlags: Set<String> = ["-gpu", "-accel", "-feature", "-port"]

    /// The emulator VMs in `ps -axo pid=,command=` output: the lines with
    /// `qemu-system` and ` -avd `, with their flags.
    ///
    /// Flags are allow-listed so nothing private is kept: a value only for
    /// `-gpu`, `-accel`, `-feature` and `-port` (and only when it is a plain
    /// word), every other `-name` without its value, so
    /// `-http-proxy user:pass@host` becomes `-http-proxy`, and never the
    /// executable's path. This is a separate parser from
    /// `EmulatorManager.parseRunningEmulators`, which drops flags and
    /// de-duplicates.
    static func parseEmulatorProcesses(psOutput: String) -> [ParsedEmulatorProcess] {
        var found: [ParsedEmulatorProcess] = []
        for rawLine in psOutput.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.contains("qemu-system"), let avdMarker = line.range(of: " -avd "),
                  let space = line.firstIndex(of: " "), let pid = Int32(line[..<space])
            else { continue }
            // The executable's path ends at the end of the last
            // `qemu-system…` word before `-avd` (the path may hold spaces).
            let beforeAvd = line[..<avdMarker.upperBound]
            guard let name = beforeAvd.range(of: "qemu-system", options: .backwards),
                  let executableEnd = line[name.upperBound...].firstIndex(of: " ")
            else { continue }
            let tokens = line[executableEnd...].split(separator: " ").map(String.init)

            var avd: String?
            var flags: [String] = []
            var grpcPort: Int?
            var consolePort: Int?
            var index = 0
            while index < tokens.count {
                let token = tokens[index]
                let next = index + 1 < tokens.count ? tokens[index + 1] : nil
                switch token {
                case "-avd":
                    avd = next
                    index += 2
                    continue
                case "-grpc":
                    if let next, let port = Int(next) {
                        grpcPort = port
                        index += 2
                    } else {
                        index += 1
                    }
                    flags.append("-grpc")
                    continue
                case _ where valueFlags.contains(token):
                    if let next {
                        if token == "-port" { consolePort = Int(next) }
                        if next.range(of: "^[A-Za-z0-9_+,.-]{1,40}$", options: .regularExpression) != nil {
                            flags.append("\(token) \(next)")
                        } else {
                            flags.append(token)
                        }
                        index += 2
                    } else {
                        flags.append(token)
                        index += 1
                    }
                    continue
                default:
                    if token.range(of: "^-[a-z][a-z0-9-]*$", options: .regularExpression) != nil {
                        flags.append(token)
                    }
                }
                index += 1
            }
            guard let avd, !avd.isEmpty else { continue }
            found.append(ParsedEmulatorProcess(pid: pid, avd: avd, flags: flags, grpcPort: grpcPort, consolePort: consolePort))
        }
        return found
    }

    /// An adb server process: its pid and the port from `-L tcp:NNNN`.
    struct ParsedAdbServer: Equatable, Sendable {
        var pid: Int32
        var port: String?
    }

    /// The adb servers in `ps` output: the lines whose program is `adb` and
    /// whose arguments hold `fork-server`.
    static func parseAdbServers(psOutput: String) -> [ParsedAdbServer] {
        var found: [ParsedAdbServer] = []
        for rawLine in psOutput.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let forkServer = line.range(of: " fork-server"),
                  let space = line.firstIndex(of: " "), let pid = Int32(line[..<space]),
                  forkServer.lowerBound > space
            else { continue }
            let command = line[line.index(after: space)..<forkServer.lowerBound]
            // The program, up to ` -L ` (or the end): its last path component is `adb`.
            let program = command.range(of: " -")
                .map { String(command[..<$0.lowerBound]) } ?? String(command)
            guard URL(fileURLWithPath: program.trimmingCharacters(in: .whitespaces)).lastPathComponent == "adb" else { continue }
            var port: String?
            if let match = line.range(of: "-L tcp:[0-9]+", options: .regularExpression) {
                port = String(line[match].dropFirst("-L tcp:".count))
            }
            found.append(ParsedAdbServer(pid: pid, port: port))
        }
        return found
    }

    /// An emulator's discovery file (`pid_<n>.ini`) as yes/no for its tokens.
    /// The gRPC token and the JWKS path are looked at, never kept (this is not
    /// `AdbParsing.emulatorDiscovery`, which returns the token).
    static func parseDiscovery(_ text: String) -> ProblemReport.Discovery {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let separator = line.firstIndex(of: "=") else { continue }
            values[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        func nonEmpty(_ key: String) -> String? {
            guard let value = values[key], !value.isEmpty else { return nil }
            return value
        }
        return ProblemReport.Discovery(
            found: true,
            emulatorVersion: nonEmpty("emulator.version"),
            emulatorBuild: nonEmpty("emulator.build"),
            avdID: nonEmpty("avd.id"),
            consolePort: nonEmpty("port.serial").flatMap { Int($0) },
            adbPort: nonEmpty("port.adb").flatMap { Int($0) },
            grpcPort: nonEmpty("grpc.port").flatMap { Int($0) },
            hasGrpcToken: nonEmpty("grpc.token") != nil,
            hasJwks: nonEmpty("grpc.jwks") != nil
        )
    }

    /// What `adb emu avd name` answered. KO is checked before the name:
    /// the console's usage errors are one line that `AdbParsing.avdName`
    /// would take for a name.
    static func classifyConsole(exitCode: Int32, stdout: Data, stderr: String) -> ProblemReport.ConsoleProbe {
        let text = String(decoding: stdout, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let sawOK = lines.contains("OK")
        let errorText = ProblemTextCut.prefix(stderr.trimmingCharacters(in: .whitespacesAndNewlines), 200)
        var probe = ProblemReport.ConsoleProbe(
            outcome: .failed,
            exitCode: exitCode,
            stdoutBytes: stdout.count,
            sawOK: sawOK,
            stderr: errorText.isEmpty ? nil : errorText
        )
        guard exitCode == 0 else { return probe }
        if trimmed.hasPrefix("KO") {
            probe.outcome = .ko
        } else if let name = AdbParsing.avdName(from: text) {
            probe.outcome = .answered
            probe.name = name
        } else {
            // Exit 0 and nothing (or only OK) on stdout.
            probe.outcome = .emptyAnswer
        }
        return probe
    }

    /// One `getprop` answer.
    static func classifyProperty(exitCode: Int32, stdout: Data, stderr: String) -> ProblemReport.PropertyProbe {
        guard exitCode == 0 else {
            let line = stderr.split(whereSeparator: \.isNewline).first.map { ProblemTextCut.prefix(String($0), 200) }
            return ProblemReport.PropertyProbe(outcome: .failed, note: line)
        }
        let value = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty
            ? ProblemReport.PropertyProbe(outcome: .empty)
            : ProblemReport.PropertyProbe(outcome: .answered, value: ProblemTextCut.prefix(value, 200))
    }
}

extension CollectionRun {
    typealias Collector = ProblemReportCollector

    struct AdbServerFacts: Sendable {
        var info: ProblemReport.AdbServer
        /// Whether the report may ask adb anything (the guard passed).
        var queryAllowed: Bool
    }

    struct ProcessFacts: Sendable {
        var emulators: [Collector.ParsedEmulatorProcess]
        /// The discovery files by the pid in their name.
        var discovery: [Int32: ProblemReport.Discovery]
        var server: AdbServerFacts
    }

    /// The running emulators, the discovery files and the adb server, with
    /// the guard that decides whether adb may be asked anything.
    ///
    /// adb is asked only when it cannot disturb the server: the report was
    /// allowed to run adb, an adb was found, a server is already running on the
    /// port adb will talk to (an adb client finding none there starts one),
    /// adb is not redirected with `ADB_SERVER_SOCKET`, the server's
    /// executable could be read, and it is the adb Device Hub Pro uses (or has
    /// the same version). Another adb's server would be restarted by an adb of
    /// a different version, and a report must change nothing.
    mutating func processes(adbVersion: String?) async -> ProcessFacts {
        var output = ""
        do {
            output = try await inputs.processList()
        } catch {
            note("Couldn\u{2019}t list the running processes.")
        }
        let emulators = Collector.parseEmulatorProcesses(psOutput: output)
        let discovery = readDiscovery()
        if discovery.keys.contains(where: { pid in !emulators.contains { $0.pid == pid } }) {
            note("A discovery file belongs to no running emulator (a leftover from one that stopped).")
        }

        let servers = Collector.parseAdbServers(psOutput: output)
        let effectivePort = environment["ANDROID_ADB_SERVER_PORT"].flatMap { !$0.isEmpty && $0.allSatisfy(\.isNumber) ? $0 : nil } ?? "5037"
        // The guard looks only at the server on the port adb will use; another
        // server is reported (it explains a "no device" answer), not asked.
        let serverOnAdbsPort = servers.first { ($0.port ?? "5037") == effectivePort }
        let server = serverOnAdbsPort ?? servers.first
        let redirected = environment["ADB_SERVER_SOCKET"].map { !$0.isEmpty } ?? false

        var info = ProblemReport.AdbServer(running: server != nil, port: server?.port)
        if let server {
            info.path = inputs.processPath(server.pid)
            if let path = info.path { info.version = toolRevision(of: URL(fileURLWithPath: path)) }
        }
        if let appPath = inputs.adbURL?.resolvingSymlinksInPath().path,
           let serverPath = info.path.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) {
            info.sameAsApp = appPath == serverPath
        }
        let reason: String?
        if !inputs.runsAdb {
            reason = "adb calls are turned off."
        } else if inputs.adbURL == nil {
            reason = "adb wasn\u{2019}t found."
        } else if redirected {
            reason = "ADB_SERVER_SOCKET sends adb to another server; the report doesn\u{2019}t ask it."
        } else if !info.running {
            reason = "No adb server is running; the report doesn\u{2019}t start one."
        } else if serverOnAdbsPort == nil {
            reason = "No adb server is running on port \(effectivePort); the report doesn\u{2019}t start one."
        } else if info.path == nil {
            reason = "Couldn\u{2019}t read which adb runs the server."
        } else if info.sameAsApp == true || (info.version != nil && info.version == adbVersion) {
            reason = nil
        } else {
            reason = "The running adb server is another adb (\(info.version ?? "unknown version")); "
                + "asking it from this adb (\(adbVersion ?? "unknown version")) could restart it."
        }
        info.queried = reason == nil
        info.notQueriedBecause = reason
        return ProcessFacts(
            emulators: emulators,
            discovery: discovery,
            server: AdbServerFacts(info: info, queryAllowed: reason == nil)
        )
    }

    /// The `pid_<n>.ini` files of the discovery folder (only listed, each
    /// read at most 64 KiB).
    private func readDiscovery() -> [Int32: ProblemReport.Discovery] {
        guard let directory = inputs.discoveryDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [:] }
        var found: [Int32: ProblemReport.Discovery] = [:]
        for name in names {
            guard name.range(of: "^pid_[0-9]+\\.ini$", options: .regularExpression) != nil,
                  let pid = Int32(name.dropFirst("pid_".count).dropLast(".ini".count))
            else { continue }
            let url = directory.appendingPathComponent(name)
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 64 * 1024) else { continue }
            found[pid] = Collector.parseDiscovery(String(decoding: data, as: UTF8.self))
        }
        return found
    }

    /// The running emulators of the process list (at most eight), before adb
    /// has been asked anything.
    mutating func runningEmulators(processes: ProcessFacts) -> [ProblemReport.RunningEmulator] {
        let limit = 8
        if processes.emulators.count > limit { note("More than \(limit) emulators run; the report lists \(limit).") }
        return processes.emulators.prefix(limit).map { process in
            let discovery = processes.discovery[process.pid] ?? (inputs.discoveryDirectory == nil ? nil : ProblemReport.Discovery(found: false))
            let consolePort = process.consolePort ?? discovery?.consolePort
            let flags = Set(process.flags)
            return ProblemReport.RunningEmulator(
                avd: process.avd,
                processAlive: inputs.processExists(process.pid),
                grpcPort: process.grpcPort ?? discovery?.grpcPort,
                consolePort: consolePort,
                serial: consolePort.map { "emulator-\($0)" },
                flags: process.flags,
                startedByDeviceHubPro: ["-qt-hide-window", "-no-boot-anim", "-grpc-use-token"].allSatisfy(flags.contains),
                discovery: discovery
            )
        }
    }

    // MARK: adb

    struct DeviceFacts {
        /// "app inventory", "adb devices -l" or "not read: <reason>".
        var source: String
        var rows: [AndroidDevice]
        var read: Bool
    }

    /// adb's device rows: the app's inventory when it supplied one (then adb
    /// is not asked), else `adb devices -l` when the guard allows it.
    mutating func devices(server: AdbServerFacts) async -> DeviceFacts {
        if let state = appState {
            return DeviceFacts(source: "app inventory", rows: state.devices, read: true)
        }
        guard server.queryAllowed, let adb = inputs.adbURL else {
            let reason = server.info.notQueriedBecause ?? "adb wasn\u{2019}t found."
            return DeviceFacts(source: "not read: \(reason)", rows: [], read: false)
        }
        switch await Self.run(.devices, adb: adb, timeout: inputs.adbCallTimeout) {
        case .finished(let exitCode, let stdout, _) where exitCode == 0:
            return DeviceFacts(
                source: "adb devices -l",
                rows: AdbParsing.devices(from: String(decoding: stdout, as: UTF8.self)),
                read: true
            )
        case .timedOut:
            note("adb devices -l did not answer in time.")
            return DeviceFacts(source: "not read: adb devices -l did not answer in time.", rows: [], read: false)
        default:
            note("adb devices -l failed.")
            return DeviceFacts(source: "not read: adb devices -l failed.", rows: [], read: false)
        }
    }

    enum AdbCallOutcome: Sendable {
        case finished(exitCode: Int32, stdout: Data, stderr: String)
        case timedOut
        case failed(String)
        case cancelled
    }

    /// Runs one of the four allowed shapes, bounded. Straight through
    /// `ProcessRunner`: the app's adb client repairs a broken server by
    /// restarting it.
    static func run(_ call: ProblemReportAdbCall, adb: URL, timeout: Duration) async -> AdbCallOutcome {
        do {
            let result = try await ProcessRunner.run(
                executable: adb,
                arguments: call.arguments,
                timeout: timeout
            )
            return .finished(exitCode: result.exitCode, stdout: result.standardOutput, stderr: result.standardErrorText)
        } catch is CancellationError {
            return .cancelled
        } catch ProcessRunnerError.timedOut {
            return .timedOut
        } catch {
            return .failed("adb could not be run")
        }
    }

    struct EmulatorProbe: Sendable {
        var console: ProblemReport.ConsoleProbe
        var guest: ProblemReport.PropertyProbe
        var boot: ProblemReport.PropertyProbe
    }

    /// How many emulators are asked.
    static let maxProbedEmulators = 4

    /// Sets each running emulator's adb state and asks the first four their
    /// console and two properties, in parallel across emulators (each one's
    /// calls in sequence). A phone is never asked anything.
    mutating func probe(
        emulators: inout [ProblemReport.RunningEmulator],
        devices: DeviceFacts,
        server: AdbServerFacts
    ) async {
        let states = Dictionary(devices.rows.map { ($0.serial, $0.state) }, uniquingKeysWith: { first, _ in first })
        for index in emulators.indices {
            emulators[index].adbState = emulators[index].serial.flatMap { states[$0] }
        }
        if emulators.count > Self.maxProbedEmulators {
            note("Only the first \(Self.maxProbedEmulators) running emulators were asked.")
        }

        let adb = inputs.adbURL
        let timeout = inputs.adbCallTimeout
        let deadline = self.deadline
        let allowed = server.queryAllowed
        let listRead = devices.read
        let targets = emulators.indices.map { index in
            (index, emulators[index].serial.flatMap(EmulatorSerial.init), emulators[index].adbState)
        }
        await withTaskGroup(of: (Int, EmulatorProbe).self) { group in
            for (index, serial, state) in targets {
                guard index < Self.maxProbedEmulators else {
                    emulators[index].console = ProblemReport.ConsoleProbe(outcome: .skipped, note: "not asked (more than four emulators)")
                    continue
                }
                group.addTask {
                    (index, await Self.probe(
                        serial: serial, state: state, listRead: listRead, adb: adb,
                        allowed: allowed, timeout: timeout, deadline: deadline
                    ))
                }
            }
            for await (index, probe) in group {
                emulators[index].console = probe.console
                emulators[index].guestAvdName = probe.guest
                emulators[index].bootCompleted = probe.boot
            }
        }
    }

    private static func probe(
        serial: EmulatorSerial?,
        state: String?,
        listRead: Bool,
        adb: URL?,
        allowed: Bool,
        timeout: Duration,
        deadline: ContinuousClock.Instant
    ) async -> EmulatorProbe {
        func skipped(_ reason: String) -> EmulatorProbe {
            EmulatorProbe(
                console: ProblemReport.ConsoleProbe(outcome: .skipped, note: reason),
                guest: ProblemReport.PropertyProbe(outcome: .skipped, note: reason),
                boot: ProblemReport.PropertyProbe(outcome: .skipped, note: reason)
            )
        }
        guard let serial else { return skipped("no console port known") }
        guard let state else { return skipped(listRead ? "not listed by adb" : "adb not queried") }
        guard allowed, let adb else { return skipped("adb not queried") }

        var result = skipped("")
        result.console = await console(serial, adb: adb, timeout: timeout, deadline: deadline)
        guard state == "device" else {
            result.guest = ProblemReport.PropertyProbe(outcome: .skipped, note: state)
            result.boot = ProblemReport.PropertyProbe(outcome: .skipped, note: state)
            return result
        }
        result.guest = await property(.guestAvdName(serial), adb: adb, timeout: timeout, deadline: deadline)
        result.boot = await property(.bootCompleted(serial), adb: adb, timeout: timeout, deadline: deadline)
        return result
    }

    private static func console(
        _ serial: EmulatorSerial,
        adb: URL,
        timeout: Duration,
        deadline: ContinuousClock.Instant
    ) async -> ProblemReport.ConsoleProbe {
        guard ContinuousClock.now < deadline, !Task.isCancelled else {
            return ProblemReport.ConsoleProbe(outcome: .skipped, note: "time budget")
        }
        switch await run(.consoleAvdName(serial), adb: adb, timeout: timeout) {
        case .finished(let exitCode, let stdout, let stderr):
            return ProblemReportCollector.classifyConsole(exitCode: exitCode, stdout: stdout, stderr: stderr)
        case .timedOut:
            return ProblemReport.ConsoleProbe(outcome: .timedOut)
        case .failed(let reason):
            return ProblemReport.ConsoleProbe(outcome: .failed, note: reason)
        case .cancelled:
            return ProblemReport.ConsoleProbe(outcome: .skipped, note: "cancelled")
        }
    }

    private static func property(
        _ call: ProblemReportAdbCall,
        adb: URL,
        timeout: Duration,
        deadline: ContinuousClock.Instant
    ) async -> ProblemReport.PropertyProbe {
        guard ContinuousClock.now < deadline, !Task.isCancelled else {
            return ProblemReport.PropertyProbe(outcome: .skipped, note: "time budget")
        }
        switch await run(call, adb: adb, timeout: timeout) {
        case .finished(let exitCode, let stdout, let stderr):
            return ProblemReportCollector.classifyProperty(exitCode: exitCode, stdout: stdout, stderr: stderr)
        case .timedOut:
            return ProblemReport.PropertyProbe(outcome: .timedOut)
        case .failed(let reason):
            return ProblemReport.PropertyProbe(outcome: .failed, note: reason)
        case .cancelled:
            return ProblemReport.PropertyProbe(outcome: .skipped, note: "cancelled")
        }
    }

    // MARK: Phones

    struct PhoneSet {
        var phones: [ProblemReport.Phone]
        /// Every serial of every phone, to its alias.
        var identifiers: [String: String]
    }

    /// The non-emulator rows as `phone-N` in list order. Their serials, the
    /// hardware serial and the other transports' serials all go to the
    /// scrubber's table; nothing here asks a phone anything.
    func phones(devices: DeviceFacts) -> PhoneSet {
        var identifiers: [String: String] = [:]
        var phones: [ProblemReport.Phone] = []
        for row in devices.rows where !row.isEmulator {
            let alias = "phone-\(phones.count + 1)"
            let serials = [row.serial] + row.alternateSerials
            for raw in serials + [row.hardwareSerial].compactMap({ $0 }) where !raw.isEmpty {
                identifiers[raw] = alias
            }
            var transports: [String] = []
            for kind in ["usb", "wifi", "mdns"] where serials.contains(where: { Self.transport(of: $0) == kind }) {
                transports.append(kind)
            }
            let version = serials.compactMap { appState?.androidVersions[$0] }.first
            phones.append(ProblemReport.Phone(
                alias: alias,
                transports: transports,
                state: row.state,
                model: row.model,
                device: row.device,
                androidVersion: version
            ))
        }
        return PhoneSet(phones: phones, identifiers: identifiers)
    }

    static func transport(of serial: String) -> String {
        if serial.contains("._adb-tls-connect._tcp") { return "mdns" }
        if serial.contains(":") { return "wifi" }
        return "usb"
    }
}
