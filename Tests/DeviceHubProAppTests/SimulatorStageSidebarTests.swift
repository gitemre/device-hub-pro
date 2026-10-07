import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// What the simulator's surfaces show, from the lifecycle's state: the
/// stage's phase and its boot-phase text, the sidebar row's subtitle and
/// icon, the platform filter, the row menu's confirmations and rename, and
/// the live stage's chrome. The entries are the lifecycle captures'
/// (`SimulatorFixtures`), named with the device-type catalog capture.
@MainActor
final class SimulatorStageSidebarTests: XCTestCase {
    private func entry(_ listing: String = "simctl-list-j-devices.booted-after-rename.json") throws -> SimulatorEntry {
        let device = try XCTUnwrap(try SimulatorFixtures.devices(listing).first { $0.udid == SimulatorFixtures.udid })
        let runtimes = try SimctlParsing.runtimes(fromListJSON: Data(contentsOf: SimulatorFixtures.url("simctl-list-j-runtimes.json")))
        let types = try SimctlParsing.deviceTypes(fromListJSON: Data(contentsOf: SimulatorFixtures.url("simctl-list-j-devicetypes.json")))
        return SimulatorEntry(device: device, runtimes: runtimes, deviceTypes: types, defaultDeviceUDIDs: [])
    }

    // MARK: - Stage

    /// Ready is the live stage; a boot shows its phase; an operation on a
    /// stopped simulator shows with a spinner; a missing runtime has nothing
    /// to start.
    func testTheStagePhase() {
        typealias Phase = SimulatorStagePhase
        func phase(_ state: DeviceRunState, _ operation: SimulatorLifecycleController.Operation? = nil) -> Phase {
            Phase.resolve(isAvailable: true, availabilityError: nil, runState: state, operation: operation, platform: "iOS")
        }
        XCTAssertEqual(phase(.ready), .live)
        XCTAssertEqual(phase(.stopped), .stopped(activity: nil))
        XCTAssertEqual(phase(.stopped, .erasing), .stopped(activity: "Erasing"))
        XCTAssertEqual(phase(.stopped, .deleting), .stopped(activity: "Removing"))
        XCTAssertEqual(phase(.stopped, .starting), .booting("Starting…"))
        XCTAssertEqual(phase(.booting(.migratingData), .starting), .booting("Migrating data…"))
        XCTAssertEqual(phase(.booting(.waitingOnHomeScreen)), .booting("Connecting display…"))
        XCTAssertEqual(phase(.booting(.other("Waiting on Data Migration"))), .booting("Waiting on Data Migration"))
        XCTAssertEqual(phase(.shuttingDown, .stopping), .stopping)
        XCTAssertEqual(phase(.unreachable), .unresponsive)
        XCTAssertEqual(
            Phase.resolve(isAvailable: false, availabilityError: "runtime profile not found", runState: .stopped, operation: nil, platform: "iOS"),
            .unavailable("runtime profile not found")
        )
    }

    /// Every boot phase `bootstatus` reports has its line, on every platform.
    func testEveryBootPhaseHasALine() {
        let phases: [DeviceBootPhase] = [.launching, .waitingOnBackBoard, .migratingData, .waitingOnSystemApp, .waitingOnHomeScreen]
        for platform in ["iOS", "tvOS", "watchOS", nil] as [String?] {
            let lines = phases.map { SimulatorStagePhase.label(for: $0, platform: platform) }
            XCTAssertEqual(Set(lines).count, phases.count)
            XCTAssertTrue(lines.allSatisfy { $0.hasSuffix("…") })
        }
    }

    /// The system app a boot waits for is the platform's home screen
    /// process: SpringBoard on iOS; tvOS has none of that name (PineBoard,
    /// the job its readiness waits for); other platforms are not named.
    func testTheSystemAppLineFollowsThePlatform() {
        XCTAssertEqual(SimulatorStagePhase.label(for: .waitingOnSystemApp, platform: "iOS"), "Waiting for SpringBoard…")
        XCTAssertEqual(SimulatorStagePhase.label(for: .waitingOnSystemApp, platform: "tvOS"), "Waiting for PineBoard…")
        XCTAssertEqual(SimulatorStagePhase.label(for: .waitingOnSystemApp, platform: "watchOS"), "Waiting for the system app…")
        XCTAssertEqual(SimulatorStagePhase.label(for: .waitingOnSystemApp, platform: nil), "Waiting for the system app…")
    }

    /// The hero is the vector body around the device type's display; none
    /// without one.
    func testTheHeroPlansTheDeviceTypesDisplay() {
        let shape = SimulatorDisplayProfile(width: 1206, height: 2622, scale: 3, topLeftRadius: 62, topRightRadius: 62, bottomRightRadius: 62, bottomLeftRadius: 62, horizontalDpi: 460)
            .displayShape(id: "iPhone-17-Pro")
        let plan = SimulatorHero.plan(shape)
        XCTAssertEqual(plan?.screenRect.size, CGSize(width: 1206, height: 2622))
        XCTAssertEqual(plan?.screenCorner.radius, 186)
        XCTAssertNil(SimulatorHero.plan(nil))
    }

    // MARK: - Sidebar

    /// On a Mac whose Xcode cannot run simulators (T0), the empty list says
    /// what to do; otherwise, and while Xcode is still being probed, the
    /// usual line.
    func testTheEmptyListGivesTheSetupAdviceAtT0() {
        let empty = "No devices match this filter."
        XCTAssertEqual(DeviceSidebarView.emptyListMessage(tooling: .unavailable), "iOS simulators and iPhones need Xcode.")
        XCTAssertEqual(DeviceSidebarView.emptyListMessage(tooling: .probing), empty)
        let firstLaunch = AppleToolingStatus(
            isProbed: true, tier: .t0, setupAdvice: "Open Xcode, accept the license and let it install its components (a few minutes), then come back.",
            xcodeVersion: "27.0", xcodeBuild: "27A266a"
        )
        XCTAssertEqual(DeviceSidebarView.emptyListMessage(tooling: firstLaunch), "Open Xcode, accept the license and let it install its components (a few minutes), then come back.")
        let ready = AppleToolingStatus(isProbed: true, tier: .t1, setupAdvice: nil, xcodeVersion: "27.0", xcodeBuild: "27A266a")
        XCTAssertEqual(DeviceSidebarView.emptyListMessage(tooling: ready), empty)
    }

    /// Device Hub's row: "Simulator" at rest, the operation in flight, a
    /// boot on its way to ready "Starting"; the OS version trails; a
    /// Dynamic-Island iPhone (17 Pro, this fixture) gets the "gen3" symbol
    /// (SB-02, 2026-09-28: DH's own sidebar reads "Iphone, Third Generation"
    /// for it).
    func testTheRow() throws {
        let entry = try entry()
        XCTAssertEqual(entry.sidebarSubtitle(runState: .ready, operation: nil), "Simulator")
        XCTAssertEqual(entry.sidebarSubtitle(runState: .stopped, operation: nil), "Simulator")
        XCTAssertEqual(entry.sidebarSubtitle(runState: .booting(.launching), operation: nil), "Starting")
        XCTAssertEqual(entry.sidebarSubtitle(runState: .booting(.launching), operation: .starting), "Starting")
        XCTAssertEqual(entry.sidebarSubtitle(runState: .shuttingDown, operation: nil), "Stopping")
        XCTAssertEqual(entry.sidebarSubtitle(runState: .stopped, operation: .erasing), "Erasing")
        XCTAssertEqual(entry.sidebarSubtitle(runState: .unreachable, operation: nil), "Not Responding")
        // The window subtitle says it the same way, in title case like
        // "Shut Down" and the stage's state.
        XCTAssertEqual(entry.statusLine(runState: .unreachable, operation: nil), "Not Responding")
        XCTAssertEqual(entry.osVersion, "27.0")
        XCTAssertEqual(entry.symbolName, "iphone.gen3")
        XCTAssertEqual(entry.deviceTypeBundlePath, "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone 17 Pro.simdevicetype")
    }

    /// The Dynamic-Island heuristic (SB-02, 2026-09-28), against every model
    /// DH's sidebar was measured with: 17 / 17 Pro / 17 Pro Max get the
    /// notch-free "gen3" frame, the "e" variant and older/base generations
    /// keep the plain "iphone" one, and a model with no generation digit
    /// (iPhone SE) falls back to the plain frame instead of crashing on the
    /// regex.
    func testTheDynamicIslandSymbolHeuristic() {
        XCTAssertEqual(SimulatorEntry.iPhoneSymbol(forModelName: "iPhone 17"), "iphone.gen3")
        XCTAssertEqual(SimulatorEntry.iPhoneSymbol(forModelName: "iPhone 17 Pro"), "iphone.gen3")
        XCTAssertEqual(SimulatorEntry.iPhoneSymbol(forModelName: "iPhone 17 Pro Max"), "iphone.gen3")
        XCTAssertEqual(SimulatorEntry.iPhoneSymbol(forModelName: "iPhone 17e"), "iphone")
        XCTAssertEqual(SimulatorEntry.iPhoneSymbol(forModelName: "iPhone 16e"), "iphone")
        XCTAssertEqual(SimulatorEntry.iPhoneSymbol(forModelName: "iPhone 16"), "iphone.gen3")
        XCTAssertEqual(SimulatorEntry.iPhoneSymbol(forModelName: "iPhone 14 Pro"), "iphone.gen3")
        XCTAssertEqual(SimulatorEntry.iPhoneSymbol(forModelName: "iPhone 14"), "iphone")
        XCTAssertEqual(SimulatorEntry.iPhoneSymbol(forModelName: "iPhone 11"), "iphone")
        XCTAssertEqual(SimulatorEntry.iPhoneSymbol(forModelName: "iPhone SE"), "iphone")
        XCTAssertEqual(SimulatorEntry.iPhoneSymbol(forModelName: nil), "iphone")
    }

    /// Reset and Remove are confirmed with the simulator's name; a running
    /// simulator's reset says it restarts. Rename needs a new, non-empty name.
    func testTheRowMenuDialogs() throws {
        let dialogs = SimulatorActionDialogs()
        let booted = try entry()
        let stopped = try entry("simctl-list-j-devices.cloned.json")

        dialogs.requestErase(booted)
        XCTAssertEqual(dialogs.confirmation, .erase(udid: booted.udid, name: "DeviceHubPro-UI-core-renamed", isRunning: true))
        // Device Hub's copy (measured on DH 27.0): curly quotes, "Don't Reset".
        XCTAssertEqual(dialogs.confirmation?.title, "Reset content and settings on \u{201C}DeviceHubPro-UI-core-renamed\u{201D}?")
        XCTAssertEqual(
            dialogs.confirmation?.message,
            "All apps, data, and settings on this simulator will be permanently deleted, and the simulator will restart. You can\u{2019}t undo this action."
        )
        XCTAssertEqual(dialogs.confirmation?.confirmTitle, "Reset")
        XCTAssertEqual(dialogs.confirmation?.alertSpec.cancelTitle, "Don\u{2019}t Reset")
        XCTAssertEqual(dialogs.confirmation?.alertSpec.style, .caution)

        dialogs.requestErase(stopped)
        XCTAssertEqual(
            dialogs.confirmation?.message,
            "All apps, data, and settings on this simulator will be permanently deleted. You can\u{2019}t undo this action."
        )

        dialogs.requestDelete(stopped)
        XCTAssertEqual(dialogs.confirmation?.title, "Remove DeviceHubPro-UI-core?")
        XCTAssertEqual(
            dialogs.confirmation?.message,
            "Removing DeviceHubPro-UI-core will delete this simulator and make it unavailable as a run destination in Xcode."
        )
        XCTAssertEqual(dialogs.confirmation?.confirmTitle, "Remove")
        XCTAssertEqual(dialogs.confirmation?.alertSpec.style, .plain, "Remove is the blue default, without an icon")

        dialogs.requestRename(booted)
        XCTAssertEqual(dialogs.renameDraft, "DeviceHubPro-UI-core-renamed")
        XCTAssertFalse(dialogs.canRename, "the same name")
        dialogs.renameDraft = "   "
        XCTAssertFalse(dialogs.canRename)
        dialogs.renameDraft = "QA iPhone"
        XCTAssertTrue(dialogs.canRename)
    }

    // MARK: - Chrome

    /// A simulator with a known display gets the vector body on the live
    /// stage (as its hero); without one, the thin bezel. Android is
    /// unchanged by the shapes.
    func testASimulatorWithAKnownDisplayGetsTheVectorBody() {
        let shape = SimulatorDisplayProfile(width: 1206, height: 2622, scale: 3).displayShape(id: "x")
        let apple = DeviceRef.apple(SimulatorFixtures.udid)
        XCTAssertEqual(DeviceChromeResolver.chrome(device: apple, avdCards: [], forceVector: false, appleDisplayShapes: [shape]), .vector)
        XCTAssertEqual(DeviceChromeResolver.chrome(device: apple, avdCards: [], forceVector: false), .thinBezel)
        XCTAssertEqual(
            DeviceChromeResolver.chrome(device: .android("R58M123"), avdCards: [], forceVector: false, appleDisplayShapes: [shape]),
            .vector
        )
    }
}
