import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The profile list the app keeps, and a profile applied through Apply to
/// Selected's path with stand-in device work.
@MainActor
final class SettingsProfileStoreTests: XCTestCase {
    private func target(_ id: String, name: String, platform: DevicePlatform, readiness: BatchReadiness = .ready) -> BatchTarget {
        BatchTarget(
            id: id, platform: platform, kind: platform == .android ? .emulator : .simulator,
            ref: platform == .android ? .android("emulator-5592") : .apple("95D9676B-3317-4BA5-8CF6-3CDD0488CACA"),
            name: name, osName: platform == .android ? "Android" : "iOS", osVersion: nil, readiness: readiness,
            apiLevel: platform == .android ? 36 : nil
        )
    }

    func testFreshStoreHasTheBuiltInsOnly() {
        let store = SettingsProfileStore(defaults: .scratch())
        XCTAssertEqual(store.profiles.map(\.name), ["Screenshots", "Dark Mode", "Accessibility Stress", "Defaults"])
        XCTAssertTrue(store.userProfiles.isEmpty)
    }

    func testUserProfilesPersistAcrossStores() {
        let defaults = UserDefaults.scratch()
        let store = SettingsProfileStore(defaults: defaults)
        XCTAssertNotNil(store.add(SettingsProfile(name: "Mine", appearance: .dark, textSize: .large)))
        let copy = store.duplicate(id: "builtin.screenshots")
        XCTAssertEqual(copy?.name, "Screenshots copy")

        let again = SettingsProfileStore(defaults: defaults)
        XCTAssertEqual(again.userProfiles.map(\.name), ["Mine", "Screenshots copy"])
        XCTAssertEqual(again.userProfiles.first?.textSize, .large)
    }

    func testRenameAndDelete() throws {
        let store = SettingsProfileStore(defaults: .scratch())
        let mine = try XCTUnwrap(store.add(SettingsProfile(name: "Mine")))
        XCTAssertTrue(store.rename(id: mine.id, to: "  Renamed "))
        XCTAssertEqual(store.profile(id: mine.id)?.name, "Renamed")
        XCTAssertFalse(store.rename(id: mine.id, to: "dark mode"), "a built-in's name is taken")
        XCTAssertFalse(store.rename(id: mine.id, to: "   "))
        XCTAssertTrue(store.delete(id: mine.id))
        XCTAssertNil(store.profile(id: mine.id))
    }

    func testBuiltInsCannotBeRenamedDeletedOrAddedOver() {
        let defaults = UserDefaults.scratch()
        let store = SettingsProfileStore(defaults: defaults)
        XCTAssertFalse(store.rename(id: "builtin.defaults", to: "Mine"))
        XCTAssertFalse(store.delete(id: "builtin.defaults"))
        XCTAssertNil(store.add(SettingsProfile(id: "builtin.fake", name: "Fake")))
        XCTAssertNil(store.add(SettingsProfile(name: "screenshots")), "a name is unique, ignoring case")
        XCTAssertEqual(store.profiles.count, 4)
        XCTAssertNil(defaults.data(forKey: AppPreferences.Keys.settingsProfiles))
    }

    func testUnreadableStoredProfilesAreKeptInABackupBeforeAnySave() throws {
        let defaults = UserDefaults.scratch()
        let broken = Data("not json".utf8)
        defaults.set(broken, forKey: AppPreferences.Keys.settingsProfiles)
        let store = SettingsProfileStore(defaults: defaults)
        XCTAssertTrue(store.userProfiles.isEmpty)
        XCTAssertEqual(defaults.data(forKey: SettingsProfileStore.backupKey), broken)
        // A save replaces the live value, never the backup.
        XCTAssertNotNil(store.add(SettingsProfile(name: "Fresh")))
        XCTAssertEqual(defaults.data(forKey: SettingsProfileStore.backupKey), broken)
        XCTAssertEqual(SettingsProfileStore(defaults: defaults).userProfiles.map(\.name), ["Fresh"])

        // One bad entry among good ones: the good load, the raw value is kept.
        let mixed = UserDefaults.scratch()
        let json = #"[{"id":"u","name":"Kept","appearance":"dark"},{"id":5}]"#
        mixed.set(Data(json.utf8), forKey: AppPreferences.Keys.settingsProfiles)
        XCTAssertEqual(SettingsProfileStore(defaults: mixed).userProfiles.map(\.name), ["Kept"])
        XCTAssertEqual(mixed.data(forKey: SettingsProfileStore.backupKey), Data(json.utf8))

        // Nothing lost, no backup.
        let clean = UserDefaults.scratch()
        let store2 = SettingsProfileStore(defaults: clean)
        store2.add(SettingsProfile(name: "A"))
        _ = SettingsProfileStore(defaults: clean)
        XCTAssertNil(clean.data(forKey: SettingsProfileStore.backupKey))
    }

    func testASecondCorruptionKeepsTheFirstBackup() throws {
        let defaults = UserDefaults.scratch()
        let first = Data("first garbage".utf8)
        defaults.set(first, forKey: AppPreferences.Keys.settingsProfiles)
        _ = SettingsProfileStore(defaults: defaults)
        XCTAssertEqual(defaults.data(forKey: SettingsProfileStore.backupKey), first)

        let second = Data("second garbage".utf8)
        defaults.set(second, forKey: AppPreferences.Keys.settingsProfiles)
        let store = SettingsProfileStore(defaults: defaults)
        XCTAssertTrue(store.userProfiles.isEmpty)
        XCTAssertEqual(defaults.data(forKey: SettingsProfileStore.backupKey), first, "the first backup is never overwritten")
        XCTAssertTrue(SettingsProfiles.readUserProfiles(second).lostData)
    }

    func testACopyNameIsFreeIgnoringCase() {
        XCTAssertEqual(SettingsProfiles.copyName(of: "Work", avoiding: ["work copy"]), "Work copy 2")
        XCTAssertEqual(SettingsProfiles.copyName(of: "Work", avoiding: ["WORK COPY", "work copy 2"]), "Work copy 3")
        XCTAssertEqual(SettingsProfiles.copyName(of: "Work", avoiding: ["Work"]), "Work copy")
    }

    func testOnlyAPlatformThatNeverOffersASettingIsLeftOutSilently() {
        XCTAssertTrue(ProfileSkip.platformNeverOffers("Controls are offered for iPhone simulators"))
        XCTAssertTrue(ProfileSkip.platformNeverOffers("A phone reports its own location"))
        XCTAssertTrue(ProfileSkip.platformNeverOffers("an emulator has no way to do this"))
        XCTAssertFalse(ProfileSkip.platformNeverOffers("The device is not ready"))
        let silent = ProfileSkip(field: "Location", reason: "an emulator has no way", isReportable: false)
        let loud = ProfileSkip(field: "Show Borders", reason: "not on this device")
        XCTAssertEqual(ProfileSkip.summary([silent, loud], on: "Pixel"), "Not applied on Pixel: Show Borders (not on this device)")
        XCTAssertNil(ProfileSkip.summary([silent], on: "Pixel"))
    }

    func testTheDefaultsProfileSaysNothingAboutLocationOnAnEmulator() {
        let emulator = BatchTarget(
            id: "A", platform: .android, kind: .emulator, ref: .android("emulator-5554"), name: "Pixel 9",
            osName: "Android", osVersion: "15", readiness: .ready, apiLevel: 35
        )
        let plan = ProfilePlanner.plan(SettingsProfiles.defaults, for: emulator)
        XCTAssertNil(ProfileSkip.summary(plan.skipped, on: "Pixel 9"))
        XCTAssertTrue(plan.skipped.contains { $0.field == "Location" })
    }

    func testAStoredValueFromANewerVersionStillLoads() {
        let defaults = UserDefaults.scratch()
        let json = #"[{"id":"u","name":"Kept","appearance":"dark","somethingNew":[1,2]}]"#
        defaults.set(Data(json.utf8), forKey: AppPreferences.Keys.settingsProfiles)
        XCTAssertEqual(SettingsProfileStore(defaults: defaults).userProfiles.map(\.name), ["Kept"])
    }

    /// A profile on three mixed devices: each ready device's backend is asked
    /// for its own plan, a stopped one is skipped.
    func testBatchApplyCallsEachDevicesBackend() async throws {
        var asked: [String: ProfilePlan] = [:]
        let status = StatusCenter()
        let multi = MultiDeviceController(status: status, picker: TestPicker()) { target, operation, _ in
            guard case .profile(let plan) = operation else { return XCTFail("\(operation)") }
            asked[target.id] = plan
        }
        let profile = SettingsProfile(name: "Mix", appearance: .dark, textSize: .large, showBorders: true)
        let result = await multi.run(.profile(profile), on: [
            target("A", name: "Pixel 9", platform: .android),
            target("S", name: "iPhone 17", platform: .apple),
            target("T", name: "Pixel 8", platform: .android, readiness: .stopped),
        ])
        let report = try XCTUnwrap(result)
        XCTAssertEqual(Set(asked.keys), ["A", "S"])
        XCTAssertEqual(asked["A"]?.operations, [.appearance(dark: true), .androidTextSize(.large), .showBorders(true)])
        XCTAssertEqual(asked["S"]?.operations, [.appearance(dark: true), .simulatorTextSize(.extraLarge), .showBorders(true)])
        XCTAssertEqual(report.succeeded, ["Pixel 9", "iPhone 17"])
        XCTAssertEqual(report.skipped.map(\.name), ["Pixel 8"])
        XCTAssertTrue(status.errorMessage?.contains("Pixel 8: Not running") == true)
    }

    func testSkippedFieldsShowInTheResultLine() async throws {
        let status = StatusCenter()
        let multi = MultiDeviceController(status: status, picker: TestPicker()) { _, _, _ in }
        // Nothing runs on the emulator (it cannot clear a location): skipped by the plan.
        _ = await multi.run(.profile(SettingsProfile(name: "Loc", location: .cleared)), on: [target("A", name: "Pixel 9", platform: .android)])
        XCTAssertTrue(status.errorMessage?.contains("Skipped") == true, status.errorMessage ?? "nil")

        let mixed = SettingsProfile(name: "Two", appearance: .light, location: .cleared)
        _ = await multi.run(.profile(mixed), on: [target("A", name: "Pixel 9", platform: .android)])
        let message = try XCTUnwrap(status.statusMessage)
        XCTAssertFalse(message.contains("Location"), "a setting the emulator never offers is left out silently: \(message)")
    }
}
