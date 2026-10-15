import Foundation
import Synchronization
import XCTest
@testable import DeviceHubProKit

/// The cache in front of the CoreSimulator Info.plist read: the stage asked
/// for the bridge's verdict dozens of times a frame and each ask read and
/// parsed the file.
final class InstalledCoreSimulatorTests: XCTestCase {
    /// A clock, a file and an environment the test moves by hand.
    private final class World: Sendable {
        private struct State {
            var instant = ContinuousClock.now
            var modified: Date? = Date(timeIntervalSince1970: 1_000)
            var version: String? = "1171.7"
            var environment: [String: String] = [:]
            var stats = 0
            var reads = 0
        }
        private let state = Mutex(State())

        var stats: Int { state.withLock { $0.stats } }
        var reads: Int { state.withLock { $0.reads } }
        func advance(_ seconds: Double) { state.withLock { $0.instant = $0.instant.advanced(by: .seconds(seconds)) } }
        func replace(version: String?, modified: Date?) { state.withLock { $0.version = version; $0.modified = modified } }
        func set(environment: [String: String]) { state.withLock { $0.environment = environment } }

        func probe(recheck: Duration = .seconds(1)) -> InstalledCoreSimulator {
            InstalledCoreSimulator(
                infoPlist: URL(fileURLWithPath: "/nonexistent/Info.plist"),
                recheckInterval: recheck,
                now: { self.state.withLock { $0.instant } },
                modificationDate: { _ in self.state.withLock { $0.stats += 1; return $0.modified } },
                readVersion: { _ in self.state.withLock { $0.reads += 1; return $0.version } },
                environment: { self.state.withLock { $0.environment } }
            )
        }
    }

    func testManyAsksWithinTheIntervalReadTheFileOnce() {
        let world = World()
        let probe = world.probe()
        for _ in 0..<500 {
            XCTAssertEqual(probe.version(), "1171.7")
            XCTAssertEqual(probe.verdict(), .allowlisted(CoreSimulatorVersion(1171, 7)))
        }
        XCTAssertEqual(world.reads, 1)
        XCTAssertEqual(world.stats, 1)
    }

    func testAfterTheIntervalOnlyTheDateIsLookedAtWhileItIsTheSame() {
        let world = World()
        let probe = world.probe()
        _ = probe.version()
        for _ in 0..<5 {
            world.advance(1.5)
            XCTAssertEqual(probe.version(), "1171.7")
        }
        XCTAssertEqual(world.stats, 6, "one look at the file a second and a half on")
        XCTAssertEqual(world.reads, 1, "the file was read once: its date never changed")
    }

    /// An Xcode update replaces the framework underneath a running app: the
    /// verdict follows within the interval, and not before.
    func testAReplacedFileIsReadAgainAndTheVerdictFlips() {
        let world = World()
        let probe = world.probe()
        XCTAssertTrue(probe.verdict().allowsBridge)
        world.replace(version: "1180.2", modified: Date(timeIntervalSince1970: 2_000))
        world.advance(0.5)
        XCTAssertEqual(probe.version(), "1171.7", "still inside the interval")
        world.advance(1)
        XCTAssertEqual(probe.version(), "1180.2")
        XCTAssertEqual(probe.verdict(), .untested(CoreSimulatorVersion(1180, 2)))
        XCTAssertFalse(probe.verdict().allowsBridge)
        XCTAssertEqual(world.reads, 2)
    }

    func testAFileThatWentAndCameBackWithAnotherDateIsReadAgain() {
        let world = World()
        let probe = world.probe()
        XCTAssertEqual(probe.version(), "1171.7")
        world.replace(version: nil, modified: nil)
        world.advance(2)
        XCTAssertNil(probe.version())
        XCTAssertEqual(probe.verdict(), .unknownVersion(nil))
        world.replace(version: "1174.9.2", modified: Date(timeIntervalSince1970: 3_000))
        world.advance(2)
        XCTAssertEqual(probe.version(), "1174.9.2")
        XCTAssertTrue(probe.verdict().allowsBridge)
    }

    func testTheEnvironmentSwitchIsReadAtEachLook() {
        let world = World()
        let probe = world.probe()
        XCTAssertTrue(probe.verdict().allowsBridge)
        world.set(environment: [BridgeCompatibility.disableVariable: "1"])
        world.advance(2)
        XCTAssertEqual(probe.verdict(), .disabled)
        XCTAssertEqual(probe.version(), "1171.7", "the switch does not change the version")
        XCTAssertEqual(world.reads, 1)
    }

    /// The same answers as the plain functions the closures used to call.
    func testItAnswersAsTheUncachedFunctionsDo() {
        let probe = InstalledCoreSimulator()
        XCTAssertEqual(probe.version(), BridgeCompatibility.installedCoreSimulatorVersion())
        XCTAssertEqual(probe.verdict(), BridgeCompatibility.verdict(coreSimulatorVersion: BridgeCompatibility.installedCoreSimulatorVersion()))
    }
}
