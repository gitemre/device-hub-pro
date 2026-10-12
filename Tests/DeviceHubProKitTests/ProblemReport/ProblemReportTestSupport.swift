import XCTest
@testable import DeviceHubProKit

/// Where the problem report tests read their fixtures (real captures, see
/// `Fixtures/problem-report/README.md`).
enum ProblemReportFixtures {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    static func url(_ path: String) -> URL {
        fixtures.appendingPathComponent(path)
    }

    static func text(_ path: String) throws -> String {
        try String(contentsOf: url(path), encoding: .utf8)
    }

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: url(path))
    }
}

/// A Mac made of a temporary folder: a home with an AVD made by an old
/// avdmanager, an SDK with the fixture packages, a discovery file and a fake
/// adb (the real `ProcessRunner` runs it). Nothing here reads this Mac's home,
/// processes or adb.
final class HermeticReportWorld {
    let root: URL
    let home: URL
    let sdk: URL
    let discovery: URL
    let adb: FakeTool

    /// The recorded `ps` of a Mac with an adb server (pid 6272) and a running
    /// emulator (pid 71988).
    static func recordedProcessList() throws -> String {
        try ProblemReportFixtures.text("api37-emulator/adb-core/host-ps-axo-pid-command.txt")
    }

    init(adbRules: [FakeTool.Rule]? = nil) throws {
        let manager = FileManager.default
        root = manager.temporaryDirectory.appendingPathComponent("ProblemReport-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        sdk = home.appendingPathComponent("Library/Android/sdk", isDirectory: true)
        discovery = root.appendingPathComponent("discovery", isDirectory: true)
        try manager.createDirectory(at: home.appendingPathComponent(".android"), withIntermediateDirectories: true)
        try manager.createDirectory(at: discovery, withIntermediateDirectories: true)

        // The AVD an old avdmanager wrote (target=android-0), in the AVD home.
        try manager.copyItem(
            at: ProblemReportFixtures.url("emulator-start/old-cmdline-tools-api37/avd"),
            to: home.appendingPathComponent(".android/avd")
        )
        // The SDK: the package properties of this Mac and Android 17's image.
        // (`emulator/package.xml` is trimmed to its <revision> element, the one
        // part `EmulatorVersion.installedVersion` reads; see the fixtures' README.)
        for path in [
            "platform-tools/source.properties", "emulator/source.properties",
            "emulator/package.xml", "cmdline-tools/latest/source.properties",
        ] {
            let target = sdk.appendingPathComponent(path)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: ProblemReportFixtures.url("problem-report/sdk/\(path)"), to: target)
        }
        try manager.copyItem(
            at: ProblemReportFixtures.url("emulator-start/old-cmdline-tools-api37/sdk/system-images"),
            to: sdk.appendingPathComponent("system-images")
        )
        // The emulator's discovery file, as its pid_<n>.ini.
        try manager.copyItem(
            at: ProblemReportFixtures.url("api37-emulator/adb-core/emulator-discovery-pid.ini"),
            to: discovery.appendingPathComponent("pid_71988.ini")
        )

        adb = try FakeTool(name: "adb", rules: adbRules ?? Self.defaultAdbRules)
        // The adb's package revision sits beside it, as in an SDK.
        try manager.copyItem(
            at: ProblemReportFixtures.url("problem-report/sdk/platform-tools/source.properties"),
            to: adb.directory.appendingPathComponent("source.properties")
        )
    }

    deinit {
        // Best effort: a leftover temporary folder must not fail a test.
        try? FileManager.default.removeItem(at: root)
    }

    static var defaultAdbRules: [FakeTool.Rule] {
        let core = "api37-emulator/adb-core"
        return [
            FakeTool.Rule("devices -l", stdoutFile: ProblemReportFixtures.url("\(core)/adb-devices-l-usb-phone.txt")),
            FakeTool.Rule("emu avd name", stdoutFile: ProblemReportFixtures.url("\(core)/emu-avd-name.txt")),
            FakeTool.Rule("ro.boot.qemu.avd_name", stdoutFile: ProblemReportFixtures.url("problem-report/emulator-getprop-avd-name.txt")),
            FakeTool.Rule("sys.boot_completed", stdoutFile: ProblemReportFixtures.url("problem-report/emulator-getprop-boot-completed.txt")),
        ]
    }

    /// The inputs of a command-line collection in this world.
    func inputs(
        processList: String? = nil,
        serverPath: String? = nil,
        producer: ProblemReport.Producer = .cli
    ) throws -> ProblemReportInputs {
        let ps = try processList ?? Self.recordedProcessList()
        let adbPath = adb.executableURL.path
        let serverExecutable = serverPath ?? adbPath
        let environment = ["PATH": root.appendingPathComponent("bin").path]
        var inputs = ProblemReportInputs.inert
        inputs.producer = producer
        inputs.homeDirectory = home
        inputs.environment = { environment }
        inputs.adbURL = adb.executableURL
        inputs.emulatorURL = sdk.appendingPathComponent("emulator/emulator")
        inputs.fixedAdbCandidates = []
        inputs.appLogDirectory = home.appendingPathComponent("Library/Logs/DeviceHubPro", isDirectory: true)
        inputs.discoveryDirectory = discovery
        inputs.diagnosticReportsDirectory = home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        inputs.identity = ScrubIdentity(homePath: home.path, userName: "testeruser", fullName: "", hostNames: [])
        inputs.macFacts = {
            MacFacts(
                macOS: "27.0", build: "27A123", model: "Mac16,10", chip: "Apple M4 Pro",
                memoryBytes: 24 * 1_073_741_824, appleSilicon: true, hypervisorSupported: true,
                insideVirtualMachine: false
            )
        }
        inputs.freeBytes = { _ in 182_000_000_000 }
        inputs.processList = { ps }
        inputs.processPath = { $0 == 6272 ? serverExecutable : nil }
        inputs.processExists = { $0 == 6272 || $0 == 71988 }
        return inputs
    }

    /// A relative path to its modification time, size and kind, for every item
    /// under `folder`: what a read-only collection must leave as it found it.
    func listing() -> [String: String] {
        let manager = FileManager.default
        var found: [String: String] = [:]
        let base = root.path
        guard let enumerator = manager.enumerator(atPath: root.path) else { return found }
        for case let relative as String in enumerator {
            let attributes = try? manager.attributesOfItem(atPath: base + "/" + relative)
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            let type = (attributes?[.type] as? FileAttributeType)?.rawValue ?? "?"
            found[relative] = "\(modified)|\(size)|\(type)"
        }
        return found
    }

    func collect(
        _ inputs: ProblemReportInputs,
        appState: ProblemReportAppState? = nil,
        subject: ProblemReport.Subject? = nil,
        recentProblems: [ProblemReport.RecentProblem] = []
    ) async -> CollectedProblemReport {
        await ProblemReportCollector.collect(
            inputs: inputs,
            appState: appState,
            subject: subject,
            recentProblems: recentProblems,
            now: Date(timeIntervalSince1970: 1_800_000_000),
            reportID: "abcd1234"
        )
    }
}

/// Preferences as a test needs them.
extension ProblemReport.Preferences {
    static let sample = ProblemReport.Preferences(
        customEmulatorBinary: false,
        customSDKFolder: false,
        emulatorAudio: "muted",
        autoRepairAvdDisplay: true,
        localNetworkInUse: false,
        showPhysicalAppleDevices: false,
        enabledPhysicalDeviceCount: 0,
        physicalFastInput: true,
        physicalNativeLiveView: true,
        developmentTeamSet: false
    )
}
