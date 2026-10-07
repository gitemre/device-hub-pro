import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// Which Controls rows the availability probes show.
final class SettingsProbeSetTests: XCTestCase {
    private struct Failure: Error {}

    /// Each settings row: the read that feeds it and the gate that shows it.
    private let rows: [(name: String, record: (inout SettingsProbeSet, Bool) -> Void, shows: (SettingsProbeSet) -> Bool)] = [
        ("Text Size", { $0.recordSystemRead(answered: $1) }, { $0.showsTextSizeRow }),
        ("Reduce Motion", { $0.recordGlobalRead(answered: $1) }, { $0.showsReduceMotionRow }),
        ("Show Borders", { $0.recordGlobalRead(answered: $1) }, { $0.showsShowBordersRow }),
        ("Increase Contrast", { $0.recordSecureRead(answered: $1) }, { $0.showsIncreaseContrastRow }),
        ("Sound", { $0.recordVolumeRead(answered: $1) }, { $0.showsSoundRow }),
        ("Data Saver", { $0.recordDataSaverRead(answered: $1) }, { $0.showsDataSaverRow }),
        (
            "TalkBack",
            { $0.recordTalkBackPackageRead(answered: $1) },
            { $0.showsTalkBackRow(talkBackPackage: "com.google.android.marvin.talkback") }
        ),
        (
            "Appearance",
            { $0.recordAppearanceRead($1 ? .success(.unreadable) : .failure(Failure())) },
            { $0.showsAppearanceSection }
        ),
    ]

    func testThreeFailuresHideARowAndAnyAnswerBringsItBack() {
        for row in rows {
            var probes = SettingsProbeSet()
            XCTAssertTrue(row.shows(probes), "\(row.name) starts shown")
            row.record(&probes, false)
            row.record(&probes, false)
            XCTAssertTrue(row.shows(probes), "\(row.name) survives two failures")
            row.record(&probes, false)
            XCTAssertFalse(row.shows(probes), "\(row.name) hides on the third")
            row.record(&probes, true)
            XCTAssertTrue(row.shows(probes), "\(row.name) returns on any answer")
        }
    }

    func testAnAnswerBetweenFailuresStartsTheCountOver() {
        var probes = SettingsProbeSet()
        probes.recordSystemRead(answered: false)
        probes.recordSystemRead(answered: false)
        probes.recordSystemRead(answered: true)
        probes.recordSystemRead(answered: false)
        probes.recordSystemRead(answered: false)
        XCTAssertTrue(probes.showsTextSizeRow)
    }

    func testAnUnrepresentableAppearanceKeepsTheRow() {
        var probes = SettingsProbeSet()
        for _ in 0..<5 {
            probes.recordAppearanceRead(.success(.unmapped("custom_schedule")))
        }
        XCTAssertTrue(probes.showsAppearanceSection)
    }

    func testTheTalkBackRowNeedsAnInstalledPackage() {
        let probes = SettingsProbeSet()
        XCTAssertFalse(probes.showsTalkBackRow(talkBackPackage: nil))
        XCTAssertTrue(probes.showsTalkBackRow(talkBackPackage: "com.android.talkback"))
    }

    // MARK: - Developer toggles

    func testANamespaceReadFeedsOnlyItsToggles() {
        var probes = SettingsProbeSet()
        for _ in 0..<3 {
            probes.recordGlobalRead(answered: false)
        }
        for toggle in DeviceToggle.allCases {
            XCTAssertEqual(
                probes.showsToggle(toggle, unsupportedToggles: []),
                toggle.namespace != "global",
                "\(toggle)"
            )
        }
        probes.recordGlobalRead(answered: true)
        XCTAssertTrue(DeviceToggle.allCases.allSatisfy { probes.showsToggle($0, unsupportedToggles: []) })
    }

    func testSystemAndSecureReadsFeedTheirToggles() {
        var probes = SettingsProbeSet()
        for _ in 0..<3 {
            probes.recordSystemRead(answered: false)
            probes.recordSecureRead(answered: false)
        }
        XCTAssertFalse(probes.showsToggle(.showTaps, unsupportedToggles: []))
        XCTAssertFalse(probes.showsToggle(.showBackgroundANRs, unsupportedToggles: []))
        XCTAssertTrue(probes.showsToggle(.forceRTL, unsupportedToggles: []))
    }

    func testAnUnsupportedToggleIsHiddenWhateverItsProbe() {
        let probes = SettingsProbeSet()
        XCTAssertFalse(probes.showsToggle(.wifiVerboseLogging, unsupportedToggles: [.wifiVerboseLogging]))
        XCTAssertTrue(probes.showsToggle(.showTaps, unsupportedToggles: [.wifiVerboseLogging]))
    }

    // MARK: - Device changes

    func testASerialChangeResetsEveryProbe() {
        var probes = SettingsProbeSet()
        XCTAssertTrue(probes.prepare(for: "emulator-5554"), "the first poll is a new device")
        for _ in 0..<3 {
            for row in rows {
                row.record(&probes, false)
            }
            probes.recordToggles(namespace: "system", answered: false)
        }
        XCTAssertTrue(rows.allSatisfy { !$0.shows(probes) })

        XCTAssertFalse(probes.prepare(for: "emulator-5554"), "the same device keeps its counts")
        XCTAssertFalse(probes.showsTextSizeRow)

        XCTAssertTrue(probes.prepare(for: "R58M123"))
        for row in rows {
            XCTAssertTrue(row.shows(probes), "\(row.name) starts over on the new device")
        }
        XCTAssertTrue(probes.toggles.isEmpty)
        XCTAssertEqual(probes.serial, "R58M123")
    }

    func testRecordTogglesWithoutAMatchingNamespaceChangesNothing() {
        var probes = SettingsProbeSet()
        probes.recordToggles(namespace: "nope", answered: false)
        XCTAssertEqual(probes, SettingsProbeSet())
    }
}
