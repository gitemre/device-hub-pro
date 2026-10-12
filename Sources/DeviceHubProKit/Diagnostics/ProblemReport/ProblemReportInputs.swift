import Darwin
import Foundation
import SystemConfiguration

/// What the running bundle says about itself.
public struct BundleFacts: Sendable, Equatable {
    public var version: String?
    public var build: String?
    /// The bundle's path, nil unless it is an `*.app`.
    public var bundlePath: String?
    /// Whether the bundle carries the `com.apple.quarantine` attribute.
    public var quarantined: Bool?

    public init(version: String? = nil, build: String? = nil, bundlePath: String? = nil, quarantined: Bool? = nil) {
        self.version = version
        self.build = build
        self.bundlePath = bundlePath
        self.quarantined = quarantined
    }
}

/// The Mac's own facts, read with `sysctlbyname` (never a process).
public struct MacFacts: Sendable, Equatable {
    /// "27.0" or "27.0.1".
    public var macOS: String
    /// `kern.osversion`.
    public var build: String?
    /// `hw.model`.
    public var model: String?
    /// `machdep.cpu.brand_string`.
    public var chip: String?
    /// `hw.memsize`.
    public var memoryBytes: Int64?
    /// `hw.optional.arm64`.
    public var appleSilicon: Bool
    /// `sysctl.proc_translated`; a missing key is false.
    public var translated: Bool
    /// `kern.hv_support`.
    public var hypervisorSupported: Bool?
    /// `kern.hv_vmm_present`.
    public var insideVirtualMachine: Bool?

    public init(
        macOS: String,
        build: String? = nil,
        model: String? = nil,
        chip: String? = nil,
        memoryBytes: Int64? = nil,
        appleSilicon: Bool,
        translated: Bool = false,
        hypervisorSupported: Bool? = nil,
        insideVirtualMachine: Bool? = nil
    ) {
        self.macOS = macOS
        self.build = build
        self.model = model
        self.chip = chip
        self.memoryBytes = memoryBytes
        self.appleSilicon = appleSilicon
        self.translated = translated
        self.hypervisorSupported = hypervisorSupported
        self.insideVirtualMachine = insideVirtualMachine
    }

    /// This Mac.
    public static func live() -> MacFacts {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = "\(version.majorVersion).\(version.minorVersion)"
            + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        return MacFacts(
            macOS: macOS,
            build: sysctlString("kern.osversion"),
            model: sysctlString("hw.model"),
            chip: sysctlString("machdep.cpu.brand_string"),
            memoryBytes: sysctlNumber("hw.memsize"),
            appleSilicon: sysctlNumber("hw.optional.arm64") == 1,
            translated: sysctlNumber("sysctl.proc_translated") == 1,
            hypervisorSupported: sysctlNumber("kern.hv_support").map { $0 == 1 },
            insideVirtualMachine: sysctlNumber("kern.hv_vmm_present").map { $0 == 1 }
        )
    }

    fileprivate static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        let text = String(decoding: buffer[..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// An integer sysctl of 4 or 8 bytes; nil when the key does not exist.
    private static func sysctlNumber(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        if size == MemoryLayout<Int32>.size {
            var value: Int32 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int64(value)
        }
        if size == MemoryLayout<Int64>.size {
            var value: Int64 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return value
        }
        return nil
    }
}

/// Everything the problem report reads from outside itself, so a test runs the
/// whole collection against a temporary folder, a stub adb and a recorded `ps`
/// without touching this Mac. `live(producer:)` is the one place that reads the
/// real home, the real environment and the real processes.
public struct ProblemReportInputs: Sendable {
    public var producer: ProblemReport.Producer
    public var homeDirectory: URL
    /// Read at collection time.
    public var environment: @Sendable () -> [String: String]
    public var bundle: BundleFacts
    /// The adb the producer uses.
    public var adbURL: URL?
    /// The emulator binary in use.
    public var emulatorURL: URL?
    /// The adb locations searched after the PATH.
    public var fixedAdbCandidates: [String]
    /// `~/Library/Logs/DeviceHubPro`; never created.
    public var appLogDirectory: URL?
    /// `~/Library/Caches/TemporaryItems/avd/running`.
    public var discoveryDirectory: URL?
    public var diagnosticReportsDirectory: URL?
    public var identity: ScrubIdentity
    public var macFacts: @Sendable () -> MacFacts
    public var freeBytes: @Sendable (URL) -> Int64?
    /// `ps -axo pid=,command=`.
    public var processList: @Sendable () async throws -> String
    /// `proc_pidpath`.
    public var processPath: @Sendable (Int32) -> String?
    /// `kill(pid, 0) == 0 || errno == EPERM`.
    public var processExists: @Sendable (Int32) -> Bool
    public var appleToolchain: @Sendable () async -> AppleToolchain?
    /// Each adb call is bounded to this.
    public var adbCallTimeout: Duration = .seconds(3)
    /// New probes stop once the collection has run this long.
    public var budget: Duration = .seconds(12)
    /// False: no adb call at all (`dhp-report collect --no-adb`).
    public var runsAdb: Bool = true

    public init(
        producer: ProblemReport.Producer,
        homeDirectory: URL,
        environment: @escaping @Sendable () -> [String: String],
        bundle: BundleFacts,
        adbURL: URL?,
        emulatorURL: URL?,
        fixedAdbCandidates: [String],
        appLogDirectory: URL?,
        discoveryDirectory: URL?,
        diagnosticReportsDirectory: URL?,
        identity: ScrubIdentity,
        macFacts: @escaping @Sendable () -> MacFacts,
        freeBytes: @escaping @Sendable (URL) -> Int64?,
        processList: @escaping @Sendable () async throws -> String,
        processPath: @escaping @Sendable (Int32) -> String?,
        processExists: @escaping @Sendable (Int32) -> Bool,
        appleToolchain: @escaping @Sendable () async -> AppleToolchain?
    ) {
        self.producer = producer
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.bundle = bundle
        self.adbURL = adbURL
        self.emulatorURL = emulatorURL
        self.fixedAdbCandidates = fixedAdbCandidates
        self.appLogDirectory = appLogDirectory
        self.discoveryDirectory = discoveryDirectory
        self.diagnosticReportsDirectory = diagnosticReportsDirectory
        self.identity = identity
        self.macFacts = macFacts
        self.freeBytes = freeBytes
        self.processList = processList
        self.processPath = processPath
        self.processExists = processExists
        self.appleToolchain = appleToolchain
    }

    /// No home, nothing found, an empty process list and no adb.
    public static let inert = ProblemReportInputs(
        producer: .app,
        homeDirectory: URL(fileURLWithPath: "/nonexistent-home", isDirectory: true),
        environment: { [:] },
        bundle: BundleFacts(),
        adbURL: nil,
        emulatorURL: nil,
        fixedAdbCandidates: [],
        appLogDirectory: nil,
        discoveryDirectory: nil,
        diagnosticReportsDirectory: nil,
        identity: ScrubIdentity(homePath: "", userName: "", fullName: "", hostNames: []),
        macFacts: { MacFacts(macOS: "unknown", appleSilicon: false) },
        freeBytes: { _ in nil },
        processList: { "" },
        processPath: { _ in nil },
        processExists: { _ in false },
        appleToolchain: { nil }
    )

    /// This Mac, for `producer`. Only `AppEnvironment.live()` and the CLI call
    /// it; the Kit's tests never do. `locatesTools: false` leaves `adbURL` and
    /// `emulatorURL` nil, for the app, which fills in the ones it uses.
    ///
    /// The host names come from SystemConfiguration and `kern.hostname`, never
    /// from `ProcessInfo.hostName` or `Host.current()`, which can block on a
    /// DNS lookup.
    public static func live(producer: ProblemReport.Producer, locatesTools: Bool = true) -> ProblemReportInputs {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment

        var diagnosticReports = home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        if let override = environment["DHP_DIAGNOSTIC_REPORTS_DIR"], !override.isEmpty {
            diagnosticReports = URL(fileURLWithPath: override, isDirectory: true)
        }

        let identity = ScrubIdentity(
            homePath: home.path,
            userName: NSUserName(),
            fullName: NSFullUserName(),
            hostNames: liveHostNames()
        )
        let processList: @Sendable () async throws -> String = {
            let result = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-axo", "pid=,command="],
                timeout: .seconds(5)
            )
            return result.standardOutputText
        }
        let processExists: @Sendable (Int32) -> Bool = { pid in kill(pid, 0) == 0 || errno == EPERM }
        let appleToolchain: @Sendable () async -> AppleToolchain? = {
            producer == .cli ? await AppleToolchain.probe() : nil
        }

        return ProblemReportInputs(
            producer: producer,
            homeDirectory: home,
            environment: { ProcessInfo.processInfo.environment },
            bundle: liveBundleFacts(),
            adbURL: locatesTools ? AdbBinaryLocator.locate(environment: environment) : nil,
            emulatorURL: locatesTools ? EmulatorManager.locateBinary(environment: environment) : nil,
            fixedAdbCandidates: AdbBinaryLocator.fixedCandidates,
            appLogDirectory: home.appendingPathComponent("Library/Logs/DeviceHubPro", isDirectory: true),
            discoveryDirectory: home.appendingPathComponent("Library/Caches/TemporaryItems/avd/running", isDirectory: true),
            diagnosticReportsDirectory: diagnosticReports,
            identity: identity,
            macFacts: { MacFacts.live() },
            freeBytes: { DiskSpaceCheck.freeBytes(at: $0) },
            processList: processList,
            processPath: { liveProcessPath($0) },
            processExists: processExists,
            appleToolchain: appleToolchain
        )
    }

    private static func liveBundleFacts() -> BundleFacts {
        let info = Bundle.main.infoDictionary
        let path = Bundle.main.bundlePath
        let isApp = path.hasSuffix(".app")
        let quarantined = isApp ? getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0 : nil
        return BundleFacts(
            version: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String,
            bundlePath: isApp ? path : nil,
            quarantined: quarantined
        )
    }

    /// The computer name, the local host name, `kern.hostname` (what `gethostname`
    /// gives, which adb writes into its key and which a DHCP or DNS name can
    /// set to something the other two do not say) with its short form, and
    /// each `.local` form.
    private static func liveHostNames() -> [String] {
        let computer = SCDynamicStoreCopyComputerName(nil, nil) as String?
        let local = SCDynamicStoreCopyLocalHostName(nil) as String?
        let kernel = MacFacts.sysctlString("kern.hostname")
        var candidates = [computer, local, kernel].compactMap { $0 }
        if let kernel, let dot = kernel.firstIndex(of: "."), dot != kernel.startIndex {
            candidates.append(String(kernel[..<dot]))
        }
        var names: [String] = []
        for name in candidates where !name.isEmpty && !["localhost", "unknown"].contains(name.lowercased()) {
            for form in [name, name + ".local"] where !names.contains(form) { names.append(form) }
        }
        return names
    }

    private static func liveProcessPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer[..<Int(length)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
