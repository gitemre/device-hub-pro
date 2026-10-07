import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The + menu's Simulators section and the New Simulator sheet (Device
/// Hub's S6/S7): the families offered, the sheet's choices over Xcode 27.0's
/// real runtime and device-type catalogs (`simctl-list-j-runtimes.json`,
/// `simctl-list-j-devicetypes.json`: iOS 26.5 and 27.0, tvOS 26.5 and 27.0),
/// its validation, the too-old rule, and `simctl create` through the
/// lifecycle on a stub that replays the real captures.
@MainActor
final class SimulatorCreateTests: XCTestCase {
    private func catalogs() throws -> (runtimes: [SimulatorRuntime], deviceTypes: [SimulatorDeviceType]) {
        (
            try SimctlParsing.runtimes(fromListJSON: Data(contentsOf: SimulatorFixtures.url("simctl-list-j-runtimes.json"))),
            try SimctlParsing.deviceTypes(fromListJSON: Data(contentsOf: SimulatorFixtures.url("simctl-list-j-devicetypes.json")))
        )
    }

    private func runtime(_ platform: String, _ version: String, supports types: [String]) -> SimulatorRuntime {
        SimulatorRuntime(
            identifier: "com.apple.CoreSimulator.SimRuntime.\(platform)-\(version.replacingOccurrences(of: ".", with: "-"))",
            name: "\(platform) \(version)",
            version: version,
            buildVersion: "",
            platform: platform,
            isAvailable: true,
            supportedDeviceTypeIdentifiers: types
        )
    }

    private static let iPhone17Pro = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
    private static let iPhone18Pro = "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"
    private static let iOS27 = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
    private static let iOS26 = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"

    // MARK: - Menu

    /// iPhone, iPad and Apple TV always; Apple Watch and Apple Vision Pro
    /// once their runtime is installed.
    func testTheFamiliesOffered() throws {
        let (runtimes, _) = try catalogs()
        // Device Hub lists all five whatever is installed; a family with no
        // runtime opens the sheet with "No Runtimes Available".
        XCTAssertEqual(SimulatorFamily.offered(runtimes: runtimes), SimulatorFamily.allCases)
        XCTAssertEqual(SimulatorFamily.offered(runtimes: []), SimulatorFamily.allCases)
        XCTAssertEqual(SimulatorFamily.allCases.map(\.menuTitle), ["iPhone…", "iPad…", "Apple Watch…", "Apple TV…", "Apple Vision Pro…"])
        XCTAssertEqual(SimulatorFamily.iPad.sheetTitle, "New iPad Simulator")
    }

    // MARK: - Draft

    /// The first model is the catalog's newest iPhone the newest runtime
    /// runs (iPhone 18 Pro, on iOS 27.0 only), named after it; the OS Version
    /// popup lists both iOS versions anyway, and picking iOS 26.5 narrows the
    /// Model popup to what it runs.
    func testAnIPhoneDraftOverTheRealCatalogs() throws {
        let (runtimes, deviceTypes) = try catalogs()
        var draft = SimulatorCreateDraft(family: .iPhone, runtimes: runtimes, deviceTypes: deviceTypes)

        XCTAssertEqual(draft.runtimes.map(\.identifier), [Self.iOS27, Self.iOS26])
        XCTAssertTrue(draft.models.allSatisfy { $0.productFamily == "iPhone" })
        XCTAssertEqual(draft.model?.identifier, Self.iPhone18Pro)
        XCTAssertEqual(draft.name, "iPhone 18 Pro")
        XCTAssertEqual(draft.osVersions.map(\.identifier), [Self.iOS27, Self.iOS26])
        XCTAssertEqual(draft.runtime?.identifier, Self.iOS27)
        XCTAssertTrue(draft.canCreate)
        XCTAssertFalse(draft.needsPlatform)

        draft.selectRuntime(Self.iOS26)
        XCTAssertEqual(draft.runtime?.identifier, Self.iOS26)
        XCTAssertFalse(draft.availableModels.contains { $0.identifier == Self.iPhone18Pro })
        XCTAssertEqual(draft.model?.identifier, draft.availableModels.first?.identifier, "the unsupported model gives way")
        XCTAssertTrue(draft.canCreate)
        draft.selectRuntime(Self.iOS27)
        draft.selectModel(Self.iPhone18Pro)

        draft.selectModel(Self.iPhone17Pro)
        XCTAssertEqual(draft.name, "iPhone 17 Pro", "the name follows the model")
        XCTAssertEqual(draft.runtime?.identifier, Self.iOS27, "the OS version it runs on stays")

        draft.selectRuntime(Self.iOS26)
        XCTAssertEqual(draft.runtime?.identifier, Self.iOS26)

        draft.selectModel(Self.iPhone18Pro)
        XCTAssertEqual(draft.runtime?.identifier, Self.iOS27, "iOS 26.5 does not run the iPhone 18 Pro")

        draft.selectRuntime("com.apple.CoreSimulator.SimRuntime.tvOS-27-0")
        XCTAssertEqual(draft.runtime?.identifier, Self.iOS27, "an OS version that cannot run the model is ignored")
    }

    /// A typed name stays across model changes; an emptied one follows the
    /// model again; a blank name cannot be created.
    func testTheName() throws {
        let (runtimes, deviceTypes) = try catalogs()
        var draft = SimulatorCreateDraft(family: .iPhone, runtimes: runtimes, deviceTypes: deviceTypes)
        draft.setName("QA Phone")
        draft.selectModel(Self.iPhone17Pro)
        XCTAssertEqual(draft.name, "QA Phone")
        XCTAssertTrue(draft.canCreate)

        // A blank field is Device Hub's placeholder: the model's name.
        draft.setName("   ")
        XCTAssertTrue(draft.canCreate)
        XCTAssertEqual(draft.name, "iPhone 17 Pro")
        draft.setName("")
        draft.selectModel(Self.iPhone18Pro)
        XCTAssertEqual(draft.name, "iPhone 18 Pro")
    }

    func testAnAppleTVDraftAndAMissingWatchRuntime() throws {
        let (runtimes, deviceTypes) = try catalogs()
        let tv = SimulatorCreateDraft(family: .appleTV, runtimes: runtimes, deviceTypes: deviceTypes)
        XCTAssertEqual(tv.runtimes.map(\.platform), ["tvOS", "tvOS"])
        XCTAssertTrue(tv.models.allSatisfy { $0.productFamily == "Apple TV" })
        XCTAssertEqual(tv.runtime?.version, "27.0")
        XCTAssertTrue(tv.canCreate)

        let watch = SimulatorCreateDraft(family: .appleWatch, runtimes: runtimes, deviceTypes: deviceTypes)
        XCTAssertTrue(watch.needsPlatform)
        XCTAssertEqual(watch.models, [])
        XCTAssertFalse(watch.canCreate)
        XCTAssertEqual(SimulatorCreateSheet.addPlatformsURL?.absoluteString, "xcode://settings/components/addSimulator")
    }

    /// A runtime older than iOS 17 (or its generation elsewhere) is not
    /// offered, like the simulators on it are not listed. The cutoff is
    /// Device Hub's (see `SimulatorOSSupport`): its CoreDevice simulator
    /// plug-in hides a device whose runtime's equivalent iOS version is
    /// below 17.0, established against Xcode 27.0 (CoreSimulator 1171.7).
    func testTooOldRuntimes() throws {
        typealias Support = SimulatorOSSupport
        XCTAssertEqual(Support.oldestEquivalentIOSMajor, 17)
        XCTAssertEqual(Support.equivalentIOSMajor(platform: "iOS", version: "17.5"), 17)
        XCTAssertEqual(Support.equivalentIOSMajor(platform: "tvOS", version: "18.0"), 18)
        XCTAssertEqual(Support.equivalentIOSMajor(platform: "watchOS", version: "10.5"), 17)
        XCTAssertEqual(Support.equivalentIOSMajor(platform: "watchOS", version: "11.0"), 18)
        XCTAssertEqual(Support.equivalentIOSMajor(platform: "watchOS", version: "26.0"), 26)
        XCTAssertEqual(Support.equivalentIOSMajor(platform: "xrOS", version: "1.2"), 17)
        XCTAssertEqual(Support.equivalentIOSMajor(platform: "xrOS", version: "2.0"), 18)
        XCTAssertNil(Support.equivalentIOSMajor(platform: "iOS", version: nil))
        XCTAssertTrue(Support.isTooOld(platform: "iOS", version: "16.4"))
        XCTAssertFalse(Support.isTooOld(platform: "iOS", version: "17.0"))
        XCTAssertFalse(Support.isTooOld(platform: "iOS", version: "17.5"))
        XCTAssertTrue(Support.isTooOld(platform: "watchOS", version: "9.4"))
        XCTAssertFalse(Support.isTooOld(platform: "xrOS", version: "1.0"))
        XCTAssertFalse(Support.isTooOld(platform: nil, version: "9.0"), "unknown platforms are kept")
        XCTAssertTrue(Support.isNewer("27.0", than: "26.5"))
        XCTAssertFalse(Support.isNewer("26.5", than: "26.5.0"))

        let (runtimes, deviceTypes) = try catalogs()
        let old = runtime("iOS", "16.4", supports: [Self.iPhone17Pro])
        let kept = runtime("iOS", "17.5", supports: [Self.iPhone17Pro])
        let draft = SimulatorCreateDraft(family: .iPhone, runtimes: runtimes + [old, kept], deviceTypes: deviceTypes)
        XCTAssertFalse(draft.runtimes.contains { $0.version == "16.4" })
        XCTAssertTrue(draft.runtimes.contains { $0.version == "17.5" })
    }

    // MARK: - simctl create

    func testCreateRunsSimctlAndReloadsTheList() async throws {
        let stub = try makeStubTool("simctl", arms: """
          *" create QA Phone \(Self.iPhone17Pro) \(Self.iOS27)")
            \(SimulatorFixtures.cat("simctl-create.stdout.txt")) ;;
          *" create Wrong \(Self.iPhone17Pro) com.apple.CoreSimulator.SimRuntime.tvOS-27-0")
            \(SimulatorFixtures.cat("simctl-create-incompatible.stdout.txt")); \(SimulatorFixtures.catToStderr("simctl-create-incompatible.stderr.txt")); exit 147 ;;
        """)
        let client = SimctlClient(simctlURL: stub.url, deviceSet: try makeTemporaryFolder("set"))
        let status = StatusCenter()
        let lifecycle = SimulatorLifecycleController(status: status)
        var reloads = 0
        lifecycle.simctlSource = { client }
        lifecycle.reloadList = { reloads += 1 }
        addTeardownBlock { @MainActor in lifecycle.stop() }

        let created = await lifecycle.create(name: "  QA Phone ", deviceTypeIdentifier: Self.iPhone17Pro, runtimeIdentifier: Self.iOS27)
        XCTAssertEqual(created, "95D9676B-3317-4BA5-8CF6-3CDD0488CACA")
        XCTAssertEqual(reloads, 1)
        XCTAssertNil(status.statusMessage, "the progress line is cleared")

        let refused = await lifecycle.create(
            name: "Wrong",
            deviceTypeIdentifier: Self.iPhone17Pro,
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.tvOS-27-0"
        )
        XCTAssertNil(refused)
        XCTAssertEqual(status.errorMessage, "Could not create Wrong: Incompatible device")
        XCTAssertEqual(reloads, 1)

        let unnamed = await lifecycle.create(name: " ", deviceTypeIdentifier: Self.iPhone17Pro, runtimeIdentifier: Self.iOS27)
        XCTAssertNil(unnamed)
        XCTAssertEqual(stub.calls.count, 2, "a blank name runs nothing")
    }
}
