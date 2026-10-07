import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// AVD creation must never replace an existing AVD (avdmanager's `-f` wiped
/// userdata and snapshots) and must never rewrite the name silently: the
/// create and rename sheets share one case-insensitive validator, and
/// `AppModel.createAvd` refuses what the validator refuses.
@MainActor
final class AvdCreateValidationTests: XCTestCase {
    // MARK: - Validator

    func testEmptyNameIsInvalid() {
        XCTAssertEqual(AvdNameValidation.validate("", existing: []), .empty)
    }

    func testNameNeedingSanitizingIsRefusedWithTheSuggestion() {
        XCTAssertEqual(
            AvdNameValidation.validate("My Pixel", existing: []),
            .invalidCharacters(suggestion: "My_Pixel")
        )
    }

    func testTakenNameIsRefusedIgnoringCase() {
        let result = AvdNameValidation.validate("pixel_9_pro_API35", existing: ["Pixel_9_Pro_API35"])
        XCTAssertEqual(result, .taken(existing: "Pixel_9_Pro_API35"))
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(
            result.message,
            "An AVD named \"Pixel_9_Pro_API35\" already exists. Choose a different name."
        )
    }

    func testRenameMayChangeOnlyTheCaseOfItsOwnName() {
        XCTAssertEqual(
            AvdNameValidation.validate("PIXEL_9", existing: ["pixel_9", "Other"], ignoring: "pixel_9"),
            .valid
        )
        XCTAssertEqual(
            AvdNameValidation.validate("other", existing: ["pixel_9", "Other"], ignoring: "pixel_9"),
            .taken(existing: "Other")
        )
    }

    func testFreeNameIsValid() {
        XCTAssertEqual(AvdNameValidation.validate("Pixel_9_2", existing: ["Pixel_9"]), .valid)
        XCTAssertNil(AvdNameValidation.valid.message)
    }

    // MARK: - Placeholder and preselection

    func testPlaceholderIsTheModelNameMadeUniqueAgainstExistingAvds() {
        let device = AvdDevice(id: "pixel_9_pro", name: "Pixel 9 Pro")
        XCTAssertEqual(AvdCreateSheet.placeholderName(device: device, existing: []), "Pixel 9 Pro")
        // Compared as the AVD name it becomes, ignoring case.
        XCTAssertEqual(
            AvdCreateSheet.placeholderName(device: device, existing: ["PIXEL_9_PRO"]),
            "Pixel 9 Pro 2"
        )
        XCTAssertEqual(
            AvdCreateSheet.placeholderName(device: device, existing: ["Pixel_9_Pro", "pixel_9_pro_2"]),
            "Pixel 9 Pro 3"
        )
        XCTAssertEqual(AvdCreateSheet.placeholderName(device: nil, existing: []), "Name")
    }

    func testEmptyFieldCreatesWithTheSanitizedPlaceholder() {
        XCTAssertEqual(
            AvdCreateSheet.effectiveName(typed: "", placeholder: "Pixel 9 Pro 2"),
            "Pixel_9_Pro_2"
        )
        XCTAssertEqual(AvdCreateSheet.effectiveName(typed: "Mine", placeholder: "Pixel 9 Pro"), "Mine")
        let placeholder = AvdCreateSheet.placeholderName(
            device: AvdDevice(id: "Galaxy Nexus", name: "Galaxy Nexus"),
            existing: []
        )
        let name = AvdCreateSheet.effectiveName(typed: "", placeholder: placeholder)
        XCTAssertEqual(AvdNameValidation.validate(name, existing: []), .valid)
    }

    func testNoErrorBeforeTheUserTypedButRealOnesAfter() {
        XCTAssertNil(AvdCreateSheet.typedNameValidation(typed: "", existing: ["Pixel_9"]))
        XCTAssertNil(AvdCreateSheet.typedNameValidation(typed: "Mine", existing: ["Pixel_9"]))
        XCTAssertEqual(
            AvdCreateSheet.typedNameValidation(typed: "My Pixel", existing: []),
            .invalidCharacters(suggestion: "My_Pixel")
        )
        XCTAssertEqual(
            AvdCreateSheet.typedNameValidation(typed: "pixel_9", existing: ["Pixel_9"]),
            .taken(existing: "Pixel_9")
        )
    }

    func testCatalogSkinPreselectsItsOwnProfile() {
        let models = [
            AvdDevice(id: "medium_phone", name: "Medium Phone"),
            AvdDevice(id: "pixel_9_pro", name: "Pixel 9 Pro"),
        ]
        XCTAssertEqual(AvdCreateSheet.preferredDeviceID(skin: "pixel_9_pro", in: models), "pixel_9_pro")
        XCTAssertEqual(AvdCreateSheet.preferredDeviceID(skin: "no_such_skin", in: models), "medium_phone")
        XCTAssertEqual(AvdCreateSheet.preferredDeviceID(skin: nil, in: models), "medium_phone")
    }

    // MARK: - Model

    func testExistingNamesIncludeTheAvdHomeAndTheModelList() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AvdCreateValidationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        try Data().write(to: home.appendingPathComponent("OnDisk.ini"))
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Orphan.avd", isDirectory: true),
            withIntermediateDirectories: true
        )
        let model = AppModel.testing()
        model.catalog.avds = ["Listed"]

        XCTAssertEqual(Set(model.catalog.existingAvdNames(avdHome: home)), ["OnDisk", "Orphan", "Listed"])
    }

    func testCreateRefusesATakenNameBeforeAvdmanagerRuns() async {
        let model = AppModel.testing()
        model.catalog.avds = ["Pixel_9_Pro_API35"]

        let failure = await model.catalog.createAvd(
            name: "pixel_9_pro_api35",
            deviceId: "pixel_9_pro",
            systemImage: "system-images;android-35;google_apis;arm64-v8a"
        )

        XCTAssertEqual(
            failure,
            "An AVD named \"Pixel_9_Pro_API35\" already exists. Choose a different name."
        )
        XCTAssertFalse(model.catalog.isCreatingAvd)
    }

    func testCreateRefusesANameItWouldHaveToRewrite() async {
        let model = AppModel.testing()

        let failure = await model.catalog.createAvd(
            name: "My Pixel",
            deviceId: "pixel_9_pro",
            systemImage: "system-images;android-35;google_apis;arm64-v8a"
        )

        XCTAssertEqual(failure, AvdNameValidation.invalidCharacters(suggestion: "My_Pixel").message)
    }

    func testCreateRefusesAnEmptyName() async {
        let model = AppModel.testing()

        let failure = await model.catalog.createAvd(
            name: "",
            deviceId: "pixel_9_pro",
            systemImage: "system-images;android-35;google_apis;arm64-v8a"
        )

        XCTAssertEqual(failure, "Enter a name.")
    }

    func testCreateRefusesASecondCreateWhileOneRuns() async {
        let model = AppModel.testing()
        model.catalog.isCreatingAvd = true

        let failure = await model.catalog.createAvd(
            name: "Fresh",
            deviceId: "pixel_9_pro",
            systemImage: "system-images;android-35;google_apis;arm64-v8a"
        )

        XCTAssertEqual(failure, "Another AVD is being created. Try again when it finishes.")
        XCTAssertTrue(model.catalog.isCreatingAvd, "the running create keeps its busy state")
    }
}
