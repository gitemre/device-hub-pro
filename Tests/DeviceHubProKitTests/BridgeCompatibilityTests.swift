import XCTest
@testable import DeviceHubProKit

/// The version gate in front of the private simulator bridge. Version strings
/// are CoreSimulator `CFBundleVersion`s: 1171.7 is the one Xcode 27.0 (27A266a)
/// installs on this Mac; 1155.4 is the build that removed `-ioSurface` and
/// moved input to dtuhidd (idb, `FBSimulatorControl/HID/SimulatorHIDTransportSelection.swift`:
/// `firstDTUHIDCoreSimulatorVersion = "1155.4"`).
final class BridgeCompatibilityTests: XCTestCase {
    private let none: [String: String] = [:]

    func testTheVerifiedMajorIsAllowlisted() {
        for version in ["1171.7", "1171", "1171.0", "1171.12.3"] {
            let verdict = BridgeCompatibility.verdict(coreSimulatorVersion: version, environment: none)
            XCTAssertEqual(verdict, .allowlisted(CoreSimulatorVersion(version)!), version)
            XCTAssertTrue(verdict.allowsBridge, version)
            XCTAssertFalse(verdict.canBeOverridden, version)
        }
    }

    func testBuildsBelowTheMinimumNeverLoadEvenWhenOverridden() {
        let override = [BridgeCompatibility.allowUntestedVariable: "1"]
        for version in ["1155.3", "1107.1", "1010.12", "0.1"] {
            let verdict = BridgeCompatibility.verdict(coreSimulatorVersion: version, allowUntested: true, environment: override)
            XCTAssertEqual(verdict, .tooOld(CoreSimulatorVersion(version)!), version)
            XCTAssertFalse(verdict.allowsBridge, version)
            XCTAssertFalse(verdict.canBeOverridden, version)
        }
    }

    /// 1155.4 is the first build with the dtuhidd/SimScreen surface, but it
    /// was never verified: untested, not too old.
    func testTheMinimumItselfIsUntestedNotTooOld() {
        XCTAssertEqual(
            BridgeCompatibility.verdict(coreSimulatorVersion: "1155.4", environment: none),
            .untested(CoreSimulatorVersion(1155, 4))
        )
        XCTAssertEqual(
            BridgeCompatibility.verdict(coreSimulatorVersion: "1155.4", allowUntested: true, environment: none),
            .untestedAllowed(CoreSimulatorVersion(1155, 4))
        )
    }

    func testAnUnknownNewerBuildIsOffUntilSomeoneOptsIn() {
        let verdict = BridgeCompatibility.verdict(coreSimulatorVersion: "1172.1", environment: none)
        XCTAssertEqual(verdict, .untested(CoreSimulatorVersion(1172, 1)))
        XCTAssertFalse(verdict.allowsBridge)
        XCTAssertTrue(verdict.canBeOverridden, "an opt-in can turn an untested build on")

        XCTAssertEqual(
            BridgeCompatibility.verdict(coreSimulatorVersion: "1172.1", allowUntested: true, environment: none),
            .untestedAllowed(CoreSimulatorVersion(1172, 1))
        )
        XCTAssertEqual(
            BridgeCompatibility.verdict(
                coreSimulatorVersion: "1200",
                environment: [BridgeCompatibility.allowUntestedVariable: "1"]
            ),
            .untestedAllowed(CoreSimulatorVersion(1200))
        )
        XCTAssertEqual(
            BridgeCompatibility.verdict(
                coreSimulatorVersion: "1200",
                environment: [BridgeCompatibility.allowUntestedVariable: "0"]
            ),
            .untested(CoreSimulatorVersion(1200)),
            "only =1 opts in"
        )
    }

    func testTheDisableVariableWinsOverEverything() {
        let disabled = [BridgeCompatibility.disableVariable: "1", BridgeCompatibility.allowUntestedVariable: "1"]
        for version in ["1171.7", "1172.1", "1100", "garbage"] {
            XCTAssertEqual(
                BridgeCompatibility.verdict(coreSimulatorVersion: version, allowUntested: true, environment: disabled),
                .disabled,
                version
            )
        }
        XCTAssertEqual(BridgeCompatibility.verdict(coreSimulatorVersion: nil, environment: disabled), .disabled)
        XCTAssertEqual(
            BridgeCompatibility.verdict(coreSimulatorVersion: "1171.7", environment: [BridgeCompatibility.disableVariable: "true"]),
            .allowlisted(CoreSimulatorVersion(1171, 7)),
            "only =1 disables, like DHP_DISABLE_MMAP"
        )
    }

    func testAnUnreadableVersionKeepsTheBridgeOff() {
        for text in [nil, "", "abc", "1171.x", "-1", "+1171", "1171..7", "1171.7 ", " "] as [String?] {
            let verdict = BridgeCompatibility.verdict(coreSimulatorVersion: text, allowUntested: true, environment: none)
            if text == "1171.7 " {
                XCTAssertEqual(verdict, .allowlisted(CoreSimulatorVersion(1171, 7)), "surrounding whitespace is trimmed")
                continue
            }
            XCTAssertEqual(verdict, .unknownVersion(text), String(describing: text))
            XCTAssertFalse(verdict.allowsBridge)
        }
    }

    func testVersionsCompareComponentByComponent() {
        XCTAssertLessThan(CoreSimulatorVersion("1155.4")!, CoreSimulatorVersion("1155.10")!)
        XCTAssertLessThan(CoreSimulatorVersion("1155.10")!, CoreSimulatorVersion("1171")!)
        XCTAssertEqual(CoreSimulatorVersion("1171")!, CoreSimulatorVersion("1171.0.0")!)
        XCTAssertEqual(Set([CoreSimulatorVersion("1171")!, CoreSimulatorVersion("1171.0")!]).count, 1)
        XCTAssertEqual(CoreSimulatorVersion("1171.7")!.major, 1171)
        XCTAssertEqual(CoreSimulatorVersion("1171.7")!.description, "1171.7")
    }

    func testTheInstalledVersionComesFromTheInfoPlist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-compat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The one key the gate reads, with the value Xcode 27.0 (27A266a)
        // installs; the rest of the framework's Info.plist is not needed.
        let plist = directory.appendingPathComponent("Info.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleVersion": "1171.7"], format: .xml, options: 0
        )
        try data.write(to: plist)
        XCTAssertEqual(BridgeCompatibility.installedCoreSimulatorVersion(infoPlist: plist), "1171.7")

        XCTAssertNil(BridgeCompatibility.installedCoreSimulatorVersion(infoPlist: directory.appendingPathComponent("missing.plist")))
        let garbage = directory.appendingPathComponent("garbage.plist")
        try Data("not a plist".utf8).write(to: garbage)
        XCTAssertNil(BridgeCompatibility.installedCoreSimulatorVersion(infoPlist: garbage))
    }

    /// Reads this Mac's own CoreSimulator (skipped without Xcode): whatever it
    /// is, the gate must be able to parse it.
    func testThisMacsCoreSimulatorVersionParses() throws {
        guard let installed = BridgeCompatibility.installedCoreSimulatorVersion() else {
            throw XCTSkip("no CoreSimulator installed")
        }
        XCTAssertNotNil(CoreSimulatorVersion(installed), installed)
        XCTAssertNotEqual(BridgeCompatibility.verdict(coreSimulatorVersion: installed, environment: none), .unknownVersion(installed))
    }

    func testAReplacedCoreSimulatorMakesTheBridgeStale() {
        XCTAssertFalse(BridgeCompatibility.isStale(loadedVersion: "1171.7", installedVersion: "1171.7"))
        XCTAssertFalse(BridgeCompatibility.isStale(loadedVersion: "1171.7", installedVersion: "1171.7.0"))
        XCTAssertTrue(BridgeCompatibility.isStale(loadedVersion: "1171.7", installedVersion: "1172.1"))
        XCTAssertTrue(BridgeCompatibility.isStale(loadedVersion: "1171.7", installedVersion: nil), "Xcode removed")
        XCTAssertFalse(BridgeCompatibility.isStale(loadedVersion: nil, installedVersion: "1172.1"), "nothing loaded yet")
    }
}
