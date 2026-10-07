import Foundation
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The physical iPhone's Info card and Controls panel at Device Hub parity.
/// The values are the captures' same-length
/// placeholders (`ApplePhysicalDeviceTests`): the real ECID, serial number and
/// UDID of the test iPhone never appear in a test.
final class PhysicalInfoParityTests: XCTestCase {
    private func info(
        entry: ApplePhysicalEntry,
        edit: ((inout [String: Any]) -> Void)? = nil
    ) throws -> PhysicalDeviceInfo {
        var data = try PhysicalFixtures.data("devicectl-info-details.json")
        if let edit {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var result = try XCTUnwrap(object["result"] as? [String: Any])
            edit(&result)
            object["result"] = result
            data = try JSONSerialization.data(withJSONObject: object)
        }
        let details = try DevicectlJSON.decode(DevicectlDeviceDetails.self, from: data).value
        let displays = try DevicectlJSON.decode(
            DevicectlDisplays.self, from: try PhysicalFixtures.data("devicectl-info-displays.json")
        ).value
        return PhysicalDeviceInfo.make(entry: entry, details: details, lockState: nil, ddi: nil, displays: displays)
    }

    // MARK: Rows and order

    /// Device Hub's rows in Device Hub's order, and none of ours by default.
    func testTheDefaultRowsAreDeviceHubsInDeviceHubsOrder() throws {
        let entry = try PhysicalFixtures.entry()
        let cards = PhysicalInfoLayout.cards(entry: entry, info: try info(entry: entry))
        XCTAssertEqual(cards.map { $0.map(\.label) }, [
            ["Name", "OS"],
            ["Capacity", "ECID", "Model", "Product Type", "Serial Number", "UDID"],
            ["Display"],
        ])
        XCTAssertEqual(PhysicalInfoProperty.defaultVisible, [
            .name, .os, .capacity, .ecid, .model, .productType, .serialNumber, .udid, .display,
        ])
        for hidden: PhysicalInfoProperty in [.osBuild, .pairing, .connection, .developerMode, .developerDiskImage, .lockState] {
            XCTAssertFalse(PhysicalInfoProperty.defaultVisible.contains(hidden), hidden.title)
        }
        // Device Hub's wording: "Product Type", "Display" without "px", "OS" without the build.
        let rows = Dictionary(uniqueKeysWithValues: cards.flatMap { $0 }.map { ($0.label, $0.value) })
        XCTAssertEqual(rows["OS"], "iOS 27.0")
        XCTAssertEqual(rows["Display"], "1170 × 2532")
        XCTAssertEqual(rows["Capacity"], "64 GB")
    }

    /// Capacity comes from `details` when it is there and is omitted, not shown
    /// empty, when it is not.
    func testCapacityIsOmittedWithoutDetailsOrWhenTheyLackIt() throws {
        let entry = try PhysicalFixtures.entry()
        let without = try info(entry: entry) { result in
            var properties = result["properties"] as? [String: Any] ?? [:]
            var hardware = properties["hardware"] as? [String: Any] ?? [:]
            hardware.removeValue(forKey: "internalStorageCapacity")
            properties["hardware"] = hardware
            result["properties"] = properties
            var legacy = result["hardwareProperties"] as? [String: Any] ?? [:]
            legacy.removeValue(forKey: "internalStorageCapacity")
            result["hardwareProperties"] = legacy
        }
        XCTAssertNil(without.capacityBytes)
        let labels = PhysicalInfoLayout.cards(entry: entry, info: without).flatMap { $0 }.map(\.label)
        XCTAssertFalse(labels.contains("Capacity"))
        XCTAssertTrue(labels.contains("ECID"), "the other details still show")

        // Not enabled: no details at all, so no Capacity, ECID or serial number either.
        let notEnabled = try PhysicalFixtures.entry(enabled: false)
        let listed = PhysicalInfoLayout.cards(entry: notEnabled, info: nil).flatMap { $0 }.map(\.label)
        XCTAssertFalse(listed.contains("Capacity"))
        XCTAssertFalse(listed.contains("ECID"))
        XCTAssertFalse(listed.contains("Serial Number"))
        XCTAssertTrue(listed.contains("UDID"), "the list has the UDID")
    }

    /// An unread Display shows two dashes on an enabled device, like Device Hub's.
    func testAnUnreadDisplayShowsTwoDashes() throws {
        let entry = try PhysicalFixtures.entry()
        let bare = PhysicalDeviceInfo.make(entry: entry, details: nil, lockState: nil, ddi: nil, displays: nil)
        let cards = PhysicalInfoLayout.cards(entry: entry, info: bare)
        XCTAssertEqual(cards.last, [.init(.display, "--")])
    }

    func testTheDetailsAreKeptAcrossAFailedRead() throws {
        let entry = try PhysicalFixtures.entry()
        let good = try info(entry: entry)
        let after = PhysicalDeviceInfo.make(
            entry: entry, details: nil, lockState: nil, ddi: nil, displays: nil, previous: good
        )
        XCTAssertEqual(after.ecid, good.ecid)
        XCTAssertEqual(after.serialNumber, good.serialNumber)
        XCTAssertEqual(after.capacityBytes, good.capacityBytes)
    }

    func testTheChecklistSectionsFollowTheCardsAndListEveryProperty() {
        let sections = PhysicalInfoProperty.Section.allCases
        XCTAssertEqual(sections, [.essential, .hardware, .displays, .connection])
        XCTAssertEqual(
            sections.flatMap(\.properties).count, PhysicalInfoProperty.allCases.count,
            "every property is in exactly one section"
        )
        XCTAssertEqual(PhysicalInfoProperty.Section.hardware.properties.map(\.title), [
            "Capacity", "ECID", "Model", "Product Type", "Serial Number", "UDID",
        ])
        XCTAssertEqual(PhysicalInfoProperty.Section.connection.properties.map(\.title), [
            "Pairing", "Connection", "Developer Mode", "Developer Disk Image", "Lock State",
        ])
        XCTAssertEqual(PhysicalInfoProperty.osBuild.title, "OS Build")
    }

    // MARK: Edit Visibility

    /// Our extra rows stay selectable in Edit Visibility: ticked, they show, in
    /// their own card at the end; unticked, a card without rows leaves.
    func testEditVisibilityShowsAndHidesRowsAndDropsEmptyCards() throws {
        let entry = try PhysicalFixtures.entry()
        var device = try info(entry: entry)
        // The lock state is one of the four reads (`lockState`), not part of `details`.
        XCTAssertNil(PhysicalInfoLayout.value(of: .lockState, entry: entry, info: device))
        device.lockState = "Unlocked"
        let ticked = PhysicalInfoProperty.defaultVisible.union([.lockState, .osBuild])
        let cards = PhysicalInfoLayout.cards(entry: entry, info: device, visible: ticked)
        XCTAssertEqual(cards.map { $0.map(\.label) }, [
            ["Name", "OS", "OS Build"],
            ["Capacity", "ECID", "Model", "Product Type", "Serial Number", "UDID"],
            ["Display"],
            ["Lock State"],
        ])
        XCTAssertEqual(PhysicalInfoLayout.value(of: .lockState, entry: entry, info: device), "Unlocked")
        // A device that is not enabled shows no lock state whatever it holds.
        let notEnabled = try PhysicalFixtures.entry(enabled: false)
        XCTAssertNil(PhysicalInfoLayout.value(of: .lockState, entry: notEnabled, info: device))

        let onlyName = PhysicalInfoLayout.cards(entry: entry, info: device, visible: [.name])
        XCTAssertEqual(onlyName.map { $0.map(\.label) }, [["Name"]])
        XCTAssertEqual(PhysicalInfoLayout.cards(entry: entry, info: device, visible: []), [])
    }

    /// The choice is kept between launches, apart from the simulators'.
    @MainActor
    func testTheVisibilityChoiceIsPersistedSeparatelyFromTheSimulators() {
        let defaults = UserDefaults.scratch()
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.physicalInfoVisible, PhysicalInfoProperty.defaultVisible)
        XCTAssertEqual(preferences.simulatorInfoVisible, SimulatorInfoProperty.defaultVisible)

        preferences.setPhysicalInfoVisible([.name, .lockState])
        XCTAssertEqual(AppPreferences(defaults: defaults).physicalInfoVisible, [.name, .lockState])
        XCTAssertEqual(
            AppPreferences(defaults: defaults).simulatorInfoVisible, SimulatorInfoProperty.defaultVisible,
            "a phone's choice leaves the simulators' alone"
        )

        preferences.setSimulatorInfoVisible([.cpuType])
        XCTAssertEqual(AppPreferences(defaults: defaults).physicalInfoVisible, [.name, .lockState])
        XCTAssertEqual(AppPreferences(defaults: defaults).simulatorInfoVisible, [.cpuType])
    }

    func testTheStoredFormIsSortedAndUnknownNamesAreIgnored() {
        XCTAssertEqual(PhysicalInfoProperty.encode([.udid, .name]), ["name", "udid"])
        XCTAssertEqual(PhysicalInfoProperty.decode(["udid", "nonsense", "name"]), [.udid, .name])
        XCTAssertEqual(PhysicalInfoProperty.decode(nil), PhysicalInfoProperty.defaultVisible, "never edited: the default")
        XCTAssertEqual(PhysicalInfoProperty.decode([]), [], "an edited, emptied choice stays empty")
    }

    /// The card has the capsule and the checklist, in the sources.
    func testTheCardOffersEditVisibility() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/DeviceHubProApp/InspectorView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("PhysicalInfoCards(entry: entry, isEditingVisibility: $isEditingVisibility)"))
        XCTAssertTrue(view.contains("PhysicalInfoVisibilityChecklist(entry: entry, info: info, model: model)"))
        XCTAssertTrue(view.contains("model.preferences.setPhysicalInfoVisible(visible)"))
    }
}

/// The physical Controls panel: Device Hub's unheaded cards in Device Hub's
/// order; a row that is not offered is simply not there.
final class PhysicalControlsCardsTests: XCTestCase {
    func testTheCardsAreDeviceHubsAndCoverTheElevenOfferedRows() {
        XCTAssertEqual(applePhysicalCardRows, [
            [.appearance, .liquidGlass, .colorFilter, .textSize, .reduceMotion, .increaseContrast,
             .showBorders, .reduceTransparency, .talkBack],
            [.location],
        ])
        XCTAssertEqual(Set(applePhysicalCardRows.flatMap { $0 }), ControlsRow.appleDeviceRows)
        XCTAssertEqual(applePhysicalCardRows.flatMap { $0 }.count, 10)
    }

    func testEveryOfferedRowShowsInItsCard() {
        let cards = applePhysicalCards(offered: ControlsRow.appleDeviceRows)
        XCTAssertEqual(cards, applePhysicalCardRows)
    }

    /// Rows the phone does not offer are not there, and a card without rows goes.
    func testUnofferedRowsAreLeftOutWithoutANote() {
        let offered: Set<ControlsRow> = [.appearance, .textSize, .reduceMotion, .location]
        XCTAssertEqual(applePhysicalCards(offered: offered), [
            [.appearance, .textSize, .reduceMotion],
            [.location],
        ])
        XCTAssertEqual(applePhysicalCards(offered: []), [])
        // Sound has no card on a phone at all (the phone lists no audio output selection).
        XCTAssertFalse(applePhysicalCardRows.flatMap { $0 }.contains(.sound))
    }

    /// No group headings and no "Not offered here" note in the physical panel.
    func testThePanelHasNoHeadingsAndNoNotes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(
            contentsOf: root.appendingPathComponent("Sources/DeviceHubProApp/Apple/ApplePhysicalControlsView.swift"),
            encoding: .utf8
        )
        for line in view.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            XCTAssertFalse(trimmed.contains("DHGroup("), trimmed)
            XCTAssertFalse(trimmed.contains("AppleControlsHiddenNote"), trimmed)
            XCTAssertFalse(trimmed.contains("Not offered here"), trimmed)
        }
        XCTAssertTrue(view.contains("applePhysicalCards("))
    }
}
