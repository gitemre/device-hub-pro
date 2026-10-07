import AppKit
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// Device Hub's quit choice (A5) for simulators: quitting shuts down the
/// simulators Device Hub Pro started, or keeps them running, per Settings' saved
/// default, and the app menu's Option alternate does the other; a simulator
/// Device Hub Pro did not start is never shut down. The model runs on a stub
/// simctl replaying the lifecycle captures (`SimulatorLifecycleFixtureTests`;
/// boot and shutdown print nothing, as the real ones do).
@MainActor
final class SimulatorQuitChoiceTests: XCTestCase {
    private static let udid = SimulatorFixtures.udid

    private func makeSimctl() throws -> StubTool {
        try makeStubTool("simctl", arms: """
          *"list -j devices")
            \(SimulatorFixtures.cat("simctl-list-j-devices.booted-after-rename.json")) ;;
          *"list -j runtimes")
            \(SimulatorFixtures.cat("simctl-list-j-runtimes.json")) ;;
          *"list -j devicetypes")
            \(SimulatorFixtures.cat("simctl-list-j-devicetypes.json")) ;;
          *" boot \(Self.udid)")
            exit 0 ;;
          *"bootstatus \(Self.udid)")
            \(SimulatorFixtures.cat("simctl-bootstatus.already-booted.stdout.txt")) ;;
          *"spawn \(Self.udid) launchctl list")
            \(SimulatorFixtures.cat("simctl-spawn-launchctl-list.ready.stdout.txt")) ;;
          *"io \(Self.udid) screenshot --type=png "*)
            \(SimulatorFixtures.screenshot("simctl-io-screenshot.home-screen-loading.png")) ;;
          *" shutdown \(Self.udid)")
            exit 0 ;;

        """)
    }

    private func shutdowns(_ simctl: StubTool) -> [String] {
        simctl.calls.filter { $0.hasPrefix("shutdown ") }
    }

    /// Settings' default (shut down): quitting shuts down the simulator
    /// Device Hub Pro started; the Option alternate keeps it running.
    func testQuitShutsDownTheSimulatorDeviceHubProStarted() async throws {
        let (model, simctl) = try await startedModel(shutsDownByDefault: true)
        XCTAssertEqual(model.simulatorLifecycle.quitChoice(shutsDownByDefault: true), .shutDownStarted)

        await model.prepareForTermination(timeout: .seconds(5))

        XCTAssertEqual(shutdowns(simctl), ["shutdown \(Self.udid)"])
    }

    func testTheAlternateKeepsItRunning() async throws {
        let (model, simctl) = try await startedModel(shutsDownByDefault: true)
        model.simulatorLifecycle.quitChoiceOverride = .keepRunning

        await model.prepareForTermination(timeout: .seconds(5))

        XCTAssertEqual(shutdowns(simctl), [])
    }

    /// Settings says keep them: quitting leaves it running, and the
    /// alternate shuts it down.
    func testTheSavedDefaultCanKeepThemRunning() async throws {
        let (model, simctl) = try await startedModel(shutsDownByDefault: false)
        XCTAssertEqual(model.simulatorLifecycle.quitChoice(shutsDownByDefault: false), .keepRunning)
        await model.prepareForTermination(timeout: .seconds(5))
        XCTAssertEqual(shutdowns(simctl), [])

        let (other, otherSimctl) = try await startedModel(shutsDownByDefault: false)
        other.simulatorLifecycle.quitChoiceOverride = .shutDownStarted
        await other.prepareForTermination(timeout: .seconds(5))
        XCTAssertEqual(shutdowns(otherSimctl), ["shutdown \(Self.udid)"])
    }

    /// A simulator booted elsewhere and only followed is never shut down,
    /// whatever the choice.
    func testASimulatorDeviceHubProDidNotStartIsNeverShutDown() async throws {
        let (model, simctl) = try await followedModel()
        XCTAssertEqual(model.simulatorLifecycle.bootedByDeviceHubPro, [])
        model.simulatorLifecycle.quitChoiceOverride = .shutDownStarted

        await model.prepareForTermination(timeout: .seconds(5))

        XCTAssertEqual(shutdowns(simctl), [])
    }

    /// A phone in another window whose stop blocks for 1.9 s does not hold
    /// back the shutdown of a simulator Device Hub Pro started: the shutdown
    /// starts at once, not after the phone's stop, so it keeps its share
    /// of the bound.
    func testASlowPhoneStopDoesNotDelayTheSimulatorShutdown() async throws {
        let (model, simctl) = try await startedModel(shutsDownByDefault: true)
        let phoneWindow = DeviceWorkspace(services: model.services)
        model.registry.register(phoneWindow)
        let phone = FakePhysicalSession(serial: "HT4CWJT01234")
        phone.stopAndWaitDelay = 1.9
        phoneWindow.beginMirrorSession(
            phone,
            device: .android(phone.serial),
            port: nil,
            capabilities: .android(emulatorGrpc: false)
        )

        let started = Date()
        let quit = Task { await model.prepareForTermination(timeout: .seconds(5)) }
        await waitUntil(timeout: 1.5, "the shutdown waited for the phone's stop") {
            !self.shutdowns(simctl).isEmpty
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "the shutdown did not wait for the phone")
        await quit.value
        XCTAssertEqual(shutdowns(simctl), ["shutdown \(Self.udid)"])
        XCTAssertEqual(phone.stopAndWaitCount, 1)
    }

    // MARK: - The menu

    private final class Target: NSObject {
        @objc func quitTheOtherWay(_ sender: Any?) {}
    }

    private func appMenu() -> (NSMenu, NSMenuItem) {
        let menu = NSMenu(title: "Device Hub Pro")
        menu.addItem(NSMenuItem(title: "About Device Hub Pro", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Device Hub Pro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)
        return (menu, quit)
    }

    /// The alternate follows Quit with its key and Option, titled for the
    /// opposite of the saved default; installing again updates it in place,
    /// and puts it back after Quit when something moved it.
    func testTheAlternateFollowsQuit() throws {
        let (menu, quit) = appMenu()
        let target = Target()
        let action = #selector(Target.quitTheOtherWay(_:))

        let item = try XCTUnwrap(SimulatorQuitMenu.install(
            in: menu, alternate: .keepRunning, isHidden: false, target: target, action: action
        ))
        XCTAssertEqual(menu.index(of: item), menu.index(of: quit) + 1)
        XCTAssertEqual(item.title, "Quit and Keep Simulators Running")
        XCTAssertTrue(item.isAlternate)
        XCTAssertEqual(item.keyEquivalent, "q")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option])
        XCTAssertTrue(item.target === target)
        XCTAssertEqual(item.action, action)
        XCTAssertFalse(item.isHidden)

        let again = try XCTUnwrap(SimulatorQuitMenu.install(
            in: menu, alternate: .shutDownStarted, isHidden: true, target: target, action: action
        ))
        XCTAssertTrue(again === item)
        XCTAssertEqual(menu.items.filter { $0.identifier == SimulatorQuitMenu.identifier }.count, 1)
        XCTAssertEqual(item.title, "Quit and Shut Down Simulators Device Hub Pro Started")
        XCTAssertTrue(item.isHidden)

        menu.removeItem(item)
        menu.insertItem(item, at: 0)
        SimulatorQuitMenu.install(in: menu, alternate: .keepRunning, isHidden: false, target: target, action: action)
        XCTAssertEqual(menu.index(of: item), menu.index(of: quit) + 1)
    }

    func testAMenuWithoutQuitGetsNothing() {
        let menu = NSMenu(title: "File")
        menu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        XCTAssertNil(SimulatorQuitMenu.install(
            in: menu, alternate: .keepRunning, isHidden: false, target: Target(), action: #selector(Target.quitTheOtherWay(_:))
        ))
        XCTAssertEqual(menu.items.count, 1)
    }

    func testTheChoices() {
        XCTAssertEqual(SimulatorLifecycleController.QuitChoice(shutsDownByDefault: true), .shutDownStarted)
        XCTAssertEqual(SimulatorLifecycleController.QuitChoice(shutsDownByDefault: false), .keepRunning)
        XCTAssertEqual(SimulatorLifecycleController.QuitChoice.shutDownStarted.opposite, .keepRunning)
        XCTAssertEqual(SimulatorLifecycleController.QuitChoice.keepRunning.opposite, .shutDownStarted)
    }

    // MARK: - Models

    /// A model whose simulator Device Hub Pro booted: a Start from the stage.
    private func startedModel(shutsDownByDefault: Bool) async throws -> (AppModel, StubTool) {
        let (model, simctl) = try await makeModel(shutsDownByDefault: shutsDownByDefault)
        await model.simulators.refresh()
        // Start: `simctl boot` (exit 0, as a boot prints nothing) makes the
        // simulator Device Hub Pro's, whatever the listing capture already says.
        let ready = await model.simulatorLifecycle.boot(Self.udid)
        XCTAssertTrue(ready)
        XCTAssertEqual(model.simulatorLifecycle.bootedByDeviceHubPro, [Self.udid])
        return (model, simctl)
    }

    /// A model that found the simulator booted and followed it.
    private func followedModel() async throws -> (AppModel, StubTool) {
        let (model, simctl) = try await makeModel(shutsDownByDefault: true)
        await model.simulators.refresh()
        await waitUntil(timeout: 10, "never ready") { model.simulatorLifecycle.isReady(Self.udid) }
        return (model, simctl)
    }

    private func makeModel(shutsDownByDefault: Bool) async throws -> (AppModel, StubTool) {
        let simctl = try makeSimctl()
        let model = AppModel.testing(apple: .stubbed(
            simctl: simctl,
            devicesDirectory: try makeTemporaryFolder("set"),
            logsDirectory: try makeTemporaryFolder("logs")
        ))
        addTeardownBlock { @MainActor in model.stopSimulatorProvider() }
        model.preferences.setShutsDownStartedSimulatorsOnQuit(shutsDownByDefault)
        return (model, simctl)
    }
}
