import XCTest
@testable import DeviceHubProKit

/// Apply to Selected's plan: which device runs what, and why the others are
/// skipped.
final class BatchPlannerTests: XCTestCase {
    private func android(
        _ id: String = "Pixel_9",
        kind: DeviceKind = .emulator,
        readiness: BatchReadiness = .ready,
        apiLevel: Int? = 36
    ) -> BatchTarget {
        BatchTarget(
            id: id,
            platform: .android,
            kind: kind,
            ref: readiness == .ready ? .android("emulator-5554") : nil,
            name: id,
            osName: "Android",
            osVersion: "16",
            readiness: readiness,
            apiLevel: apiLevel
        )
    }

    private func simulator(
        _ id: String = "95D9676B-3317-4BA5-8CF6-3CDD0488CACA",
        osName: String? = "iOS",
        readiness: BatchReadiness = .ready
    ) -> BatchTarget {
        BatchTarget(
            id: id,
            platform: .apple,
            kind: .simulator,
            ref: .apple(id),
            name: "iPhone 17 Pro",
            osName: osName,
            osVersion: "27.0",
            readiness: readiness
        )
    }

    private let apk = BatchBuild(url: URL(fileURLWithPath: "/tmp/app.apk"), platform: .android)
    private let app = BatchBuild(url: URL(fileURLWithPath: "/tmp/App.app"), platform: .apple)

    // MARK: Readiness

    func testADeviceThatIsNotReadyIsSkippedWithItsState() {
        let cases: [(BatchReadiness, String)] = [
            (.starting, "Still starting"),
            (.stopped, "Not running"),
            (.offline, "Offline"),
            (.unauthorized, "Not authorized: allow USB debugging on the phone"),
            (.unavailable(""), "Unavailable"),
            (.unavailable("iOS 26.0 is not installed"), "Unavailable: iOS 26.0 is not installed"),
            (.notListed, "No longer listed"),
        ]
        for (readiness, reason) in cases {
            XCTAssertEqual(BatchPlanner.step(.screenshot, for: android(readiness: readiness)), .skip(reason))
            XCTAssertEqual(BatchPlanner.step(.screenshot, for: simulator(readiness: readiness)), .skip(reason))
        }
        XCTAssertNil(BatchReadiness.ready.skipReason)
    }

    func testThePlanIsKeyedByTheRowsID() {
        let steps = BatchPlanner.plan(
            .appearance(dark: true),
            for: [android("Pixel_9"), android("Pixel_8", readiness: .stopped), simulator("UDID-1")]
        )
        XCTAssertEqual(steps, [
            "Pixel_9": .run(.appearance(dark: true)),
            "Pixel_8": .skip("Not running"),
            "UDID-1": .run(.appearance(dark: true)),
        ])
    }

    // MARK: Android

    func testAndroidTextSizeTakesTheStepAndItsAPILevel() {
        XCTAssertEqual(BatchPlanner.step(.textSize(.large), for: android(apiLevel: 30)), .run(.androidTextSize(.large)))
        XCTAssertEqual(BatchPlanner.step(.textSize(.doubled), for: android(apiLevel: 34)), .run(.androidTextSize(.percent200)))
        XCTAssertEqual(
            BatchPlanner.step(.textSize(.doubled), for: android(apiLevel: 33)),
            .skip("200% text needs Android 14 or later (API 34)")
        )
        // An unknown level is not refused: the write reads the device back.
        XCTAssertEqual(BatchPlanner.step(.textSize(.doubled), for: android(apiLevel: nil)), .run(.androidTextSize(.percent200)))
    }

    func testOnlyAnEmulatorTakesASimulatedLocation() {
        let place = BatchPlace(name: "Istanbul", latitude: 41.0082, longitude: 28.9784)
        XCTAssertEqual(
            BatchPlanner.step(.location(place), for: android(kind: .emulator)),
            .run(.location(latitude: 41.0082, longitude: 28.9784))
        )
        XCTAssertEqual(
            BatchPlanner.step(.location(place), for: android("R5CT", kind: .physical)),
            .skip("A phone reports its own location: a simulated one needs an emulator")
        )
    }

    func testAnAndroidLinkIsValidatedForTheDevice() throws {
        let request = try LinkRequest("https://example.com/a", browsable: true, package: nil, apiLevel: 36)
        XCTAssertEqual(BatchPlanner.step(.openURL("  https://example.com/a \n"), for: android()), .run(.openAndroidLink(request)))
        XCTAssertEqual(BatchPlanner.step(.openURL("example.com"), for: android()), .skip("The link has no scheme"))
        XCTAssertEqual(BatchPlanner.step(.openURL("   "), for: android()), .skip("The link is empty"))
    }

    func testEachPlatformInstallsItsOwnBuild() {
        XCTAssertEqual(BatchPlanner.step(.install([app, apk]), for: android()), .run(.install(apk)))
        XCTAssertEqual(BatchPlanner.step(.install([apk, app]), for: simulator()), .run(.install(app)))
        XCTAssertEqual(
            BatchPlanner.step(.install([app]), for: android()),
            .skip("No Android build chosen (.apk, .apks or a folder of split APKs)")
        )
        XCTAssertEqual(
            BatchPlanner.step(.install([apk]), for: simulator()),
            .skip("No simulator build chosen (.app, .ipa or .zip)")
        )
    }

    func testDemoModeNeedsAndroid6() {
        XCTAssertEqual(BatchPlanner.step(.statusBar(clean: true), for: android(apiLevel: 23)), .run(.statusBar(clean: true)))
        XCTAssertEqual(BatchPlanner.step(.statusBar(clean: false), for: android(apiLevel: 22)), .skip("Demo mode needs Android 6.0 or later"))
        XCTAssertEqual(BatchPlanner.step(.statusBar(clean: true), for: android(apiLevel: nil)), .run(.statusBar(clean: true)))
    }

    func testAndroidLanguageAndScreenshotRun() throws {
        let turkish = try XCTUnwrap(DeviceLocale(tag: "tr-TR"))
        XCTAssertEqual(BatchPlanner.step(.language(turkish), for: android()), .run(.language(turkish)))
        XCTAssertEqual(BatchPlanner.step(.screenshot, for: android("R5CT", kind: .physical)), .run(.screenshot))
    }

    // MARK: Simulators

    func testASimulatorTakesTheNearestContentSize() {
        XCTAssertEqual(BatchPlanner.step(.textSize(.standard), for: simulator()), .run(.simulatorTextSize(.large)))
        XCTAssertEqual(BatchPlanner.step(.textSize(.doubled), for: simulator()), .run(.simulatorTextSize(.accessibilityLarge)))
    }

    func testControlsAreOnlyOfferedOnIOSSimulators() throws {
        let tv = simulator(osName: "tvOS")
        let reason = "Controls are offered for iPhone and iPad simulators, not tvOS"
        let turkish = try XCTUnwrap(DeviceLocale(tag: "tr-TR"))
        let place = BatchPlace(latitude: 1, longitude: 2)
        for action: BatchAction in [
            .appearance(dark: true), .textSize(.large), .language(turkish), .location(place), .statusBar(clean: true),
        ] {
            XCTAssertEqual(BatchPlanner.step(action, for: tv), .skip(reason), action.title)
        }
        // Not Controls: screenshots, links and builds reach every simulator.
        XCTAssertEqual(BatchPlanner.step(.screenshot, for: tv), .run(.screenshot))
        XCTAssertEqual(BatchPlanner.step(.install([app]), for: tv), .run(.install(app)))
        // A simulator whose platform is not known yet is taken for iOS.
        XCTAssertEqual(BatchPlanner.step(.appearance(dark: false), for: simulator(osName: nil)), .run(.appearance(dark: false)))
        XCTAssertEqual(
            BatchPlanner.step(.location(place), for: simulator()),
            .run(.location(latitude: 1, longitude: 2))
        )
    }

    func testASimulatorLinkIsReadAsSimctlReadsIt() throws {
        let url = try XCTUnwrap(URL(string: "myapp://open?id=1"))
        XCTAssertEqual(BatchPlanner.step(.openURL(" myapp://open?id=1 "), for: simulator()), .run(.openSimulatorURL(url)))
        XCTAssertEqual(
            BatchPlanner.step(.openURL("example.com"), for: simulator()),
            .skip("Not a URL: it needs a scheme, such as https: or myapp:")
        )
        XCTAssertEqual(
            BatchPlanner.step(.openURL("file:///tmp/a.txt"), for: simulator()),
            .skip("A file on the Mac: a simulator opens links, not files")
        )
        XCTAssertEqual(
            BatchPlanner.step(.openURL("https://exa mple.com"), for: simulator()),
            .skip("Cannot be read as a URL")
        )
    }

    // MARK: Steps

    func testAStepExposesItsOperationOrItsReason() {
        XCTAssertEqual(BatchStep.run(.screenshot).operation, .screenshot)
        XCTAssertNil(BatchStep.run(.screenshot).skipReason)
        XCTAssertEqual(BatchStep.skip("Offline").skipReason, "Offline")
        XCTAssertNil(BatchStep.skip("Offline").operation)
    }

    func testATargetsOSLabelJoinsWhatIsKnown() {
        XCTAssertEqual(simulator().osLabel, "iOS 27.0")
        XCTAssertEqual(simulator(osName: nil).osLabel, "27.0")
        let unnamed = BatchTarget(
            id: "x", platform: .android, kind: .physical, ref: nil, name: "x",
            osName: "Android", osVersion: nil, readiness: .stopped
        )
        XCTAssertEqual(unnamed.osLabel, "Android")
        let blank = BatchTarget(
            id: "y", platform: .android, kind: .physical, ref: nil, name: "y",
            osName: nil, osVersion: nil, readiness: .stopped
        )
        XCTAssertNil(blank.osLabel)
    }
}

/// The action values Apply to Selected offers.
final class BatchActionTests: XCTestCase {
    func testTitlesNameTheActionAndItsValue() throws {
        let turkish = try XCTUnwrap(DeviceLocale(tag: "tr_TR"))
        XCTAssertEqual(BatchAction.appearance(dark: true).title, "Dark Appearance")
        XCTAssertEqual(BatchAction.appearance(dark: false).title, "Light Appearance")
        XCTAssertEqual(BatchAction.textSize(.standard).title, "Text Size Default")
        XCTAssertEqual(BatchAction.textSize(.doubled).title, "Text Size 200%")
        XCTAssertEqual(BatchAction.language(turkish).title, "Language tr-TR")
        XCTAssertEqual(BatchAction.location(BatchPlace(name: "Home", latitude: 0, longitude: 0)).title, "Location Home")
        XCTAssertEqual(BatchAction.openURL("https://example.com").title, "Open URL")
        XCTAssertEqual(BatchAction.install([]).title, "Install Build")
        XCTAssertEqual(BatchAction.statusBar(clean: true).title, "Clean Status Bar")
        XCTAssertEqual(BatchAction.statusBar(clean: false).title, "Clear Status Bar")
        XCTAssertEqual(BatchAction.screenshot.title, "Screenshot")
    }

    func testTextSizesAreAndroidsStockSteps() {
        XCTAssertEqual(BatchTextSize.allCases.map(\.androidStep), [.small, .standard, .large, .largest, .percent200])
        XCTAssertEqual(BatchTextSize.allCases.map(\.scale), [0.85, 1.0, 1.15, 1.3, 2.0])
        XCTAssertEqual(BatchTextSize.allCases.map(\.label), ["Small", "Default", "Large", "Largest", "200%"])
    }

    /// Body is 14/15/16/17/19/21/23 pt, then 28/33/40/47/53 pt (HIG, Dynamic
    /// Type sizes, iOS): 17 pt is 1.0.
    func testASimulatorTakesTheCategoryWhoseBodySizeIsNearestTheScale() {
        XCTAssertEqual(BatchTextSize.allCases.map(\.simulatorSize), [
            .extraSmall,             // 0.85 × 17 = 14.45 pt: 14
            .large,                  // 17
            .extraLarge,             // 19.55: 19
            .extraExtraExtraLarge,   // 22.1: 23
            .accessibilityLarge,     // 34: 33
        ])
        XCTAssertEqual(SimulatorContentSize.nearest(toScale: 100), .accessibilityExtraExtraExtraLarge)
        XCTAssertEqual(SimulatorContentSize.nearest(toScale: 0), .extraSmall)
    }

    func testATieGoesToTheSmallerCategory() {
        // Midway between 14 and 15 pt.
        XCTAssertEqual(SimulatorContentSize.nearest(toScale: 14.5 / 17), .extraSmall)
    }

    func testEverySettableCategoryHasABodySize() {
        XCTAssertTrue(SimulatorContentSize.settable.allSatisfy { $0.bodyPointSize != nil })
        XCTAssertNil(SimulatorContentSize.unknown.bodyPointSize)
        XCTAssertNil(SimulatorContentSize.unsupported.bodyPointSize)
    }

    func testAPlaceIsNamedOrShowsItsCoordinate() {
        XCTAssertEqual(BatchPlace(name: "Istanbul", latitude: 41, longitude: 29).title, "Istanbul")
        XCTAssertEqual(BatchPlace(name: "", latitude: 41.00824, longitude: 28.97836).title, "41.0082, 28.9784")
        XCTAssertEqual(BatchPlace(latitude: 37.422, longitude: -122.084).title, "37.4220, -122.0840")
    }

    func testABuildBelongsToThePlatformItsNameSays() {
        func platform(_ path: String, isDirectory: Bool = false) -> DevicePlatform? {
            BatchBuild.classify(URL(fileURLWithPath: path), isDirectory: isDirectory)?.platform
        }
        XCTAssertEqual(platform("/tmp/app-debug.apk"), .android)
        XCTAssertEqual(platform("/tmp/app.APKS"), .android)
        XCTAssertEqual(platform("/tmp/splits", isDirectory: true), .android)
        XCTAssertEqual(platform("/tmp/Runner.app", isDirectory: true), .apple)
        XCTAssertEqual(platform("/tmp/Runner.ipa"), .apple)
        XCTAssertEqual(platform("/tmp/Runner.zip"), .apple)
        XCTAssertNil(platform("/tmp/notes.txt"))
        XCTAssertNil(platform("/tmp/archive"))
    }

    func testTheCommonLanguagesAllParse() {
        XCTAssertEqual(BatchLocales.common.count, 19)
        XCTAssertEqual(BatchLocales.common.first?.tag, "en-US")
        XCTAssertEqual(BatchLocales.common.suffix(2).map(\.tag), ["zh-Hans-CN", "zh-Hant-TW"])
        XCTAssertEqual(Set(BatchLocales.common.map(\.tag)).count, 19)
    }
}
