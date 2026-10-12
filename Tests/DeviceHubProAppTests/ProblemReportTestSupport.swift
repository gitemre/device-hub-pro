import Foundation
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// Where the app's problem report tests read the Kit's real captures: the
/// recorded `ps` of a Mac with an adb server and a running emulator, the
/// emulator's discovery file and the answers of `adb emu avd name` and
/// `getprop` (see `Fixtures/problem-report/README.md`).
enum AppProblemReportFixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DeviceHubProKitTests/Fixtures", isDirectory: true)

    static func url(_ path: String) -> URL {
        root.appendingPathComponent(path)
    }

    static func text(_ path: String) throws -> String {
        try String(contentsOf: url(path), encoding: .utf8)
    }
}

/// A Mac made of a temporary folder for the Report a Problem sheet: a home, a
/// discovery folder holding the recorded emulator's file, the recorded `ps`
/// (an adb server, pid 6272, and an emulator, pid 71988) and a fake adb that
/// answers the three emulator reads from the real captures and logs every call.
/// Nothing here reads this Mac's home, processes or adb.
@MainActor
final class ProblemReportWorld {
    let root: URL
    let home: URL
    let discovery: URL
    let adb: StubAdb
    private let processListText: String

    /// The phone of the recorded `adb devices -l` (its serial must never reach
    /// a call or the report).
    static let phoneSerial = "0a1b2c3d4e5f"

    init(test: XCTestCase) throws {
        let manager = FileManager.default
        root = manager.temporaryDirectory.appendingPathComponent("ProblemReportApp-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        discovery = root.appendingPathComponent("discovery", isDirectory: true)
        try manager.createDirectory(at: home.appendingPathComponent(".android"), withIntermediateDirectories: true)
        try manager.createDirectory(at: discovery, withIntermediateDirectories: true)
        try manager.copyItem(
            at: AppProblemReportFixtures.url("api37-emulator/adb-core/emulator-discovery-pid.ini"),
            to: discovery.appendingPathComponent("pid_71988.ini")
        )
        processListText = try AppProblemReportFixtures.text("api37-emulator/adb-core/host-ps-axo-pid-command.txt")

        let consoleName = AppProblemReportFixtures.url("api37-emulator/adb-core/emu-avd-name.txt").path
        let guestName = AppProblemReportFixtures.url("problem-report/emulator-getprop-avd-name.txt").path
        let bootCompleted = AppProblemReportFixtures.url("problem-report/emulator-getprop-boot-completed.txt").path
        adb = try test.makeStubAdb(arms: """
          "-s emulator-5554 emu avd name") cat '\(consoleName)' ;;
          "-s emulator-5554 shell getprop ro.boot.qemu.avd_name") cat '\(guestName)' ;;
          "-s emulator-5554 shell getprop sys.boot_completed") cat '\(bootCompleted)' ;;
        """)
        test.addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root) }
    }

    /// The report inputs of this Mac: the recorded processes, with the fake adb
    /// as the server's executable, so the adb-server guard passes.
    func inputs() -> ProblemReportInputs {
        let ps = processListText
        let serverPath = adb.client.adbURL.path
        var inputs = ProblemReportInputs.inert
        inputs.producer = .app
        inputs.homeDirectory = home
        inputs.environment = { [root] in ["PATH": root.appendingPathComponent("bin").path] }
        inputs.fixedAdbCandidates = []
        inputs.appLogDirectory = home.appendingPathComponent("Library/Logs/DeviceHubPro", isDirectory: true)
        inputs.discoveryDirectory = discovery
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
        inputs.processPath = { $0 == 6272 ? serverPath : nil }
        inputs.processExists = { $0 == 6272 || $0 == 71988 }
        return inputs
    }

    /// A model on the fake adb whose environment reads this Mac.
    func makeModel(
        launch: LaunchOptions = .none,
        defaults: UserDefaults = .scratch()
    ) -> AppModel {
        var environment = AppEnvironment.testing(adb: adb.client, launch: launch, defaults: defaults)
        let reportInputs = inputs()
        environment.problemReportInputs = { reportInputs }
        let model = AppModel(environment: environment)
        // What the sidebar would hold after a refresh: the recorded emulator
        // and a phone, adb's rows without anything being asked.
        model.inventory.setRealDevices([
            .online("emulator-5554"),
            AndroidDevice(serial: Self.phoneSerial, state: "device", model: "2209116AG"),
        ])
        return model
    }

    /// A relative path to its modification time, size and kind for every item
    /// under the world's folder: what a read-only collection must leave as it
    /// found it.
    func listing() -> [String: String] {
        let manager = FileManager.default
        var found: [String: String] = [:]
        guard let enumerator = manager.enumerator(atPath: root.path) else { return found }
        for case let relative as String in enumerator {
            let attributes = try? manager.attributesOfItem(atPath: root.path + "/" + relative)
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            found[relative] = "\(modified)|\(size)"
        }
        return found
    }
}

/// The sheet model on a model's own inputs and snapshot, with its seams held
/// by the test.
@MainActor
struct SheetHarness {
    let sheet: ProblemReportSheetModel
    let pasteboard: TestPasteboard
    let picker: TestPicker
    let status: StatusCenter
    let opened: OpenedURLs

    /// The URLs `openIssue()` handed to the browser.
    @MainActor
    final class OpenedURLs {
        var urls: [URL] = []
    }

    init(model: AppModel, subject: ProblemReport.Subject? = nil) {
        let pasteboard = TestPasteboard()
        let picker = TestPicker()
        let status = StatusCenter()
        let opened = OpenedURLs()
        self.sheet = ProblemReportSheetModel(
            subject: subject,
            inputs: model.problemReportInputs(),
            state: model.problemReportState(),
            recentProblems: model.services.environment.recentProblems,
            pasteboard: pasteboard,
            picker: picker,
            status: status,
            openURL: { opened.urls.append($0) },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        self.pasteboard = pasteboard
        self.picker = picker
        self.status = status
        self.opened = opened
    }
}
