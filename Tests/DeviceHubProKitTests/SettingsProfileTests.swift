import XCTest
@testable import DeviceHubProKit

/// Settings profiles: their coding (tolerant of what it does not know), the
/// built-ins, what each platform takes of a profile and what it reports as
/// not applied, and what "Save Current Settings" captures.
final class SettingsProfileTests: XCTestCase {
    private func android(
        api: Int? = 36, kind: DeviceKind = .emulator, readiness: BatchReadiness = .ready
    ) -> BatchTarget {
        BatchTarget(
            id: "avd:Pixel", platform: .android, kind: kind, ref: .android("emulator-5592"),
            name: "Pixel 9", osName: "Android", osVersion: "16", readiness: readiness, apiLevel: api
        )
    }

    private func simulator(osName: String? = "iOS") -> BatchTarget {
        BatchTarget(
            id: "simulator:U", platform: .apple, kind: .simulator,
            ref: .apple("95D9676B-3317-4BA5-8CF6-3CDD0488CACA"),
            name: "iPhone 17", osName: osName, osVersion: "27.0", readiness: .ready
        )
    }

    // MARK: - Coding

    func testProfileRoundTrips() throws {
        let profile = SettingsProfile(
            name: "Mine", appearance: .dark, textSize: .large, reduceMotion: true,
            increaseContrast: false, showBorders: true, screenReader: false,
            location: ProfileLocation(latitude: 41.0, longitude: 29.0, name: "Istanbul"),
            language: "tr-TR", timeFormat: .twentyFourHour, statusBar: .clean
        )
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(SettingsProfile.self, from: data), profile)
    }

    func testUnknownKeysAreIgnored() throws {
        let json = #"{"id":"a","name":"Old","appearance":"dark","futureThing":{"x":1},"textSize":"largest"}"#
        let profile = try JSONDecoder().decode(SettingsProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.appearance, .dark)
        XCTAssertEqual(profile.textSize, .largest)
        XCTAssertNil(profile.reduceMotion)
    }

    func testAValueItCannotReadDropsThatFieldOnly() throws {
        let json = #"{"id":"a","name":"N","appearance":"sepia","textSize":"small","reduceMotion":"yes"}"#
        let profile = try JSONDecoder().decode(SettingsProfile.self, from: Data(json.utf8))
        XCTAssertNil(profile.appearance)
        XCTAssertNil(profile.reduceMotion)
        XCTAssertEqual(profile.textSize, .small)
    }

    func testStoredListSkipsAnUnreadableEntryAndBuiltInIDs() throws {
        let json = """
        [{"id":"u1","name":"Keep"},{"name":"no id"},{"id":"builtin.screenshots","name":"Fake"},
         {"id":"u1","name":"Duplicate id"},{"id":"u2","name":"Also keep","appearance":"light"}]
        """
        let profiles = SettingsProfiles.decodeUserProfiles(Data(json.utf8))
        XCTAssertEqual(profiles.map(\.name), ["Keep", "Also keep"])
        XCTAssertTrue(SettingsProfiles.decodeUserProfiles(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(SettingsProfiles.decodeUserProfiles(nil).isEmpty)
    }

    func testEncodingLeavesBuiltInsOut() throws {
        let user = SettingsProfile(name: "Mine", appearance: .light)
        let data = try XCTUnwrap(SettingsProfiles.encodeUserProfiles(SettingsProfiles.builtIns + [user]))
        XCTAssertEqual(SettingsProfiles.decodeUserProfiles(data), [user])
    }

    // MARK: - Built-ins

    func testBuiltInsAreNamedAndNeverTurnAScreenReaderOn() {
        XCTAssertEqual(
            SettingsProfiles.builtIns.map(\.name),
            ["Screenshots", "Dark Mode", "Accessibility Stress", "Defaults"]
        )
        XCTAssertTrue(SettingsProfiles.builtIns.allSatisfy(\.isBuiltIn))
        XCTAssertTrue(SettingsProfiles.builtIns.allSatisfy { $0.screenReader != true })
        XCTAssertEqual(SettingsProfiles.screenshots.statusBar, .clean)
        XCTAssertEqual(SettingsProfiles.darkMode.appearance, .dark)
        XCTAssertEqual(SettingsProfiles.accessibilityStress.textSize, .doubled)
        XCTAssertEqual(SettingsProfiles.accessibilityStress.reduceMotion, true)
        XCTAssertEqual(SettingsProfiles.accessibilityStress.increaseContrast, true)
    }

    func testDuplicateOfABuiltInIsAUserProfile() {
        let copy = SettingsProfiles.screenshots.duplicated(named: "Shots")
        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertNotEqual(copy.id, SettingsProfiles.screenshots.id)
        XCTAssertEqual(copy.statusBar, .clean)
        XCTAssertEqual(SettingsProfiles.copyName(of: "A", avoiding: ["A copy", "A copy 2"]), "A copy 3")
        XCTAssertEqual(SettingsProfiles.copyName(of: "A", avoiding: ["a COPY"]), "A copy 2", "case does not matter")
    }

    // MARK: - Mapping per platform

    func testAccessibilityStressOnAndroid() {
        let plan = ProfilePlanner.plan(SettingsProfiles.accessibilityStress, for: android())
        XCTAssertEqual(plan.operations, [
            .androidTextSize(.percent200), .reduceMotion(true), .increaseContrast(true),
        ])
        XCTAssertTrue(plan.skipped.isEmpty)
    }

    func testAccessibilityStressOnASimulatorUsesItsContentSize() {
        let plan = ProfilePlanner.plan(SettingsProfiles.accessibilityStress, for: simulator())
        XCTAssertEqual(plan.operations, [
            .simulatorTextSize(BatchTextSize.doubled.simulatorSize), .reduceMotion(true), .increaseContrast(true),
        ])
    }

    func testScreenshotsCleansTheStatusBarOnBoth() {
        XCTAssertEqual(
            ProfilePlanner.plan(SettingsProfiles.screenshots, for: android()).operations,
            [.androidTextSize(.standard), .statusBar(clean: true)]
        )
        XCTAssertEqual(
            ProfilePlanner.plan(SettingsProfiles.screenshots, for: simulator()).operations,
            [.simulatorTextSize(.large), .statusBar(clean: true)]
        )
    }

    func testDefaultsPutsEverythingBack() {
        let ios = ProfilePlanner.plan(SettingsProfiles.defaults, for: simulator()).operations
        XCTAssertEqual(ios, [
            .appearance(dark: false), .simulatorTextSize(.large), .reduceMotion(false),
            .increaseContrast(false), .showBorders(false), .screenReader(false), .clearLocation,
            .timeFormat(.localeDefault), .statusBar(clean: false),
        ])
    }

    // MARK: - Skipped fields

    func testAFieldAPlatformCannotTakeIsSkippedAndNamed() {
        // An emulator cannot clear a location; Android 13 has no 200 % text.
        let plan = ProfilePlanner.plan(SettingsProfiles.defaults, for: android(api: 33))
        XCTAssertTrue(plan.operations.contains(.androidTextSize(.standard)))
        XCTAssertEqual(plan.skipped.map(\.field), ["Location"])
        let stress = ProfilePlanner.plan(SettingsProfiles.accessibilityStress, for: android(api: 33))
        XCTAssertEqual(stress.skipped.map(\.field), ["Text Size"])
        let line = ProfileSkip.summary(stress.skipped, on: "Pixel 9") ?? ""
        XCTAssertTrue(line.hasPrefix("Not applied on Pixel 9: Text Size ("), line)
    }

    func testAPhoneKeepsItsOwnLocation() {
        let profile = SettingsProfile(name: "P", location: ProfileLocation(latitude: 1, longitude: 2))
        let plan = ProfilePlanner.plan(profile, for: android(kind: .physical))
        XCTAssertTrue(plan.operations.isEmpty)
        XCTAssertEqual(plan.skipped.map(\.field), ["Location"])
    }

    func testATvOSSimulatorTakesNothing() {
        let plan = ProfilePlanner.plan(SettingsProfiles.darkMode, for: simulator(osName: "tvOS"))
        XCTAssertTrue(plan.operations.isEmpty)
        XCTAssertEqual(plan.skipped.map(\.field), ["Appearance"])
    }

    func testABadLanguageTagIsSkipped() {
        let plan = ProfilePlanner.plan(SettingsProfile(name: "L", language: "!!"), for: android())
        XCTAssertTrue(plan.operations.isEmpty)
        XCTAssertEqual(plan.skipped.map(\.field), ["Language"])
    }

    func testBatchPlannerRunsAProfileAndSkipsAnEmptyOrNotReadyOne() {
        let run = BatchPlanner.step(.profile(SettingsProfiles.darkMode), for: android())
        guard case .run(.profile(let plan)) = run else { return XCTFail("\(run)") }
        XCTAssertEqual(plan.operations, [.appearance(dark: true)])
        XCTAssertEqual(
            BatchPlanner.step(.profile(SettingsProfiles.darkMode), for: android(readiness: .stopped)).skipReason,
            "Not running"
        )
        XCTAssertNotNil(BatchPlanner.step(.profile(SettingsProfile(name: "Empty")), for: android()).skipReason)
        XCTAssertEqual(BatchAction.profile(SettingsProfiles.darkMode).title, "Profile “Dark Mode”")
    }

    // MARK: - Capture

    func testCapturingReadingsBuildsAProfile() {
        let readings = ProfileReadings(
            dark: true, textScale: 1.3, reduceMotion: false, increaseContrast: true,
            latitude: 41.0, longitude: 29.0, languageTag: "tr-TR", timeFormat: .twentyFourHour,
            statusBarClean: true
        )
        let profile = SettingsProfile.capturing(readings, named: "Now")
        XCTAssertEqual(profile.appearance, .dark)
        XCTAssertEqual(profile.textSize, .largest)
        XCTAssertEqual(profile.reduceMotion, false)
        XCTAssertEqual(profile.increaseContrast, true)
        XCTAssertNil(profile.showBorders)
        XCTAssertEqual(profile.location?.coordinate?.latitude, 41.0)
        XCTAssertEqual(profile.language, "tr-TR")
        XCTAssertEqual(profile.timeFormat, .twentyFourHour)
        XCTAssertEqual(profile.statusBar, .clean)
        XCTAssertFalse(profile.isBuiltIn)
        XCTAssertTrue(SettingsProfile.capturing(ProfileReadings(), named: "Nothing").isEmpty)
    }
}
