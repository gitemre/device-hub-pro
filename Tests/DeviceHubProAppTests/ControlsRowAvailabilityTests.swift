import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// The table that says which Controls row works on which device family
/// (`ControlsRow.availability(on:)`). Its evidence is in the source and in
/// the parity audit (CT-FAM): SDK hardware profiles for Android TV, Wear
/// OS, automotive and XR, simctl answers on a tvOS 27.0 simulator for Apple TV.
@MainActor
final class ControlsRowAvailabilityTests: XCTestCase {
    private let androidFamilies = ControlsFamily.allCases.filter { $0.platform == .android }
    private let appleFamilies = ControlsFamily.allCases.filter { $0.platform == .apple }

    private func unavailable(_ family: ControlsFamily) -> Set<ControlsRow> {
        Set(ControlsRow.allCases.filter { !$0.availability(on: family).isVisible })
    }

    private func shown(_ family: ControlsFamily) -> Set<ControlsRow> {
        Set(ControlsRow.allCases.filter { $0.availability(on: family).isVisible })
    }

    // MARK: - Shape of the table

    /// A row of another platform is `hidden`; a row of this platform that a
    /// family cannot work is `unsupported` with a reason; nothing else is hidden.
    func testHiddenMeansAnotherPlatformsRowAndUnsupportedSaysWhy() {
        for family in ControlsFamily.allCases {
            for row in ControlsRow.allCases {
                switch row.availability(on: family) {
                case .hidden:
                    XCTAssertFalse(row.platforms.contains(family.platform), "\(row) on \(family)")
                case .unsupported(let reason):
                    XCTAssertTrue(row.platforms.contains(family.platform), "\(row) on \(family)")
                    XCTAssertFalse(reason.isEmpty, "\(row) on \(family)")
                case .available:
                    XCTAssertTrue(row.platforms.contains(family.platform), "\(row) on \(family)")
                }
            }
        }
    }

    /// No family may lose the rows of the manifest's platform wholesale by accident:
    /// every family with a panel shows at least one row.
    func testEveryFamilyWithAPanelShowsRows() {
        for family in ControlsFamily.allCases where family.hasControlsPanel {
            XCTAssertFalse(shown(family).isEmpty, "\(family)")
        }
        for family in [ControlsFamily.appleWatch, .appleVision] {
            XCTAssertFalse(family.hasControlsPanel)
            XCTAssertTrue(shown(family).isEmpty, "\(family): no runtime to measure, no rows")
        }
    }

    // MARK: - Android

    /// The class every row was built for keeps every Android row: the panel of a
    /// phone, a foldable or a tablet does not change.
    func testHandheldKeepsEveryAndroidRow() {
        let android = Set(ControlsRow.allCases.filter { $0.platforms.contains(.android) })
        XCTAssertEqual(shown(.androidHandheld), android)
    }

    func testWearOSHasNoStatusBarAppearanceOrPresets() {
        let gone = unavailable(.androidWear).intersection(ControlsRow.allCases.filter { $0.platforms.contains(.android) })
        XCTAssertEqual(gone, [
            .cleanStatusBar,
            .appearance, .dataSaver,
        ])
        // A watch still has a battery, a touch screen and cellular rows.
        XCTAssertTrue(ControlsRow.battery.availability(on: .androidWear).isVisible)
        XCTAssertTrue(ControlsRow.showTaps.availability(on: .androidWear).isVisible)
        XCTAssertTrue(ControlsRow.location.availability(on: .androidWear).isVisible)
    }

    func testTVHasNoBatteryTouchStatusBarOrCellular() {
        for row in [ControlsRow.battery, .charging, .batterySaver, .showTaps,
                    .cleanStatusBar, .airplaneMode, .mobileData,
                    .meteredMobileData, .dataSaver] {
            XCTAssertFalse(row.availability(on: .androidTV).isVisible, "\(row)")
            XCTAssertNotNil(row.availability(on: .androidTV).reason, "\(row)")
        }
        for row in [ControlsRow.wifi, .bluetooth, .location, .appearance, .textSize, .deviceLanguage,
                    .targetApp, .linkURL, .networkSpeed, .connectionLatency, .talkBack] {
            XCTAssertTrue(row.availability(on: .androidTV).isVisible, "\(row)")
        }
        XCTAssertTrue(ControlsRow.battery.availability(on: .androidTV).reason?.contains("power-type") == true)
    }

    func testAutomotiveAndXRKeepWhatTheirProfilesHave() {
        XCTAssertFalse(ControlsRow.battery.availability(on: .androidAutomotive).isVisible)
        XCTAssertTrue(ControlsRow.cleanStatusBar.availability(on: .androidAutomotive).isVisible, "status-bar true on all 8 profiles")
        XCTAssertTrue(ControlsRow.showTaps.availability(on: .androidAutomotive).isVisible, "a touch screen")
        XCTAssertFalse(ControlsRow.showTaps.availability(on: .androidXR).isVisible)
        XCTAssertTrue(ControlsRow.battery.availability(on: .androidXR).isVisible)
        XCTAssertTrue(ControlsRow.showTaps.availability(on: .androidDesktop).isVisible)
    }

    func testAndroidGroupsDropWhatTheFamilyCannotWork() {
        var all = ControlsGroupAvailability()
        all.canUseEmulatorControls = true
        all.appearance = true
        all.showTaps = true
        all.backgroundANRs = true
        all.statusBar = true
        all.networkConditions = true
        all.shaping = true
        all.appConditions = true

        let handheld = controlsGroups(all).map(\.id)
        XCTAssertEqual(controlsGroups(all, family: .androidHandheld).map(\.id), handheld)
        XCTAssertEqual(controlsTrailingRows(all), [.cleanStatusBar])
        XCTAssertTrue(handheld.contains(.power))

        let tv = controlsGroups(all, family: .androidTV)
        XCTAssertFalse(tv.map(\.id).contains(.power), "a TV has no battery: the group leaves with its rows")
        XCTAssertEqual(controlsTrailingRows(all, family: .androidTV), [], "a TV has no status bar")
        XCTAssertEqual(tv.first { $0.id == .debugAndInput }?.rows, [.backgroundANRs], "no touches on a TV")
        XCTAssertEqual(tv.first { $0.id == .network }?.rows, [.wifi, .bluetooth, .networkSpeed, .connectionLatency, .resetConditions])

        let wear = controlsGroups(all, family: .androidWear)
        XCTAssertEqual(controlsTrailingRows(all, family: .androidWear), [], "a watch has no status bar")
        XCTAssertTrue(wear.map(\.id).contains(.power))
        XCTAssertEqual(wear.first { $0.id == .displayAndSound }?.rows ?? [], [])
    }

    func testAndroidFamilyComesFromTheDeviceClass() {
        XCTAssertEqual(ControlsFamily.android(nil), .androidHandheld)
        XCTAssertEqual(ControlsFamily.android(.handheld), .androidHandheld)
        XCTAssertEqual(ControlsFamily.android(.wear), .androidWear)
        XCTAssertEqual(ControlsFamily.android(.tv), .androidTV)
        XCTAssertEqual(ControlsFamily.android(.automotive), .androidAutomotive)
        XCTAssertEqual(ControlsFamily.android(.xr), .androidXR)
        XCTAssertEqual(ControlsFamily.android(.desktop), .androidDesktop)
    }

    // MARK: - Apple

    func testIPhoneAndIPadKeepEveryAppleRow() {
        let apple = Set(ControlsRow.allCases.filter { $0.platforms.contains(.apple) })
        XCTAssertEqual(shown(.iPhone), apple)
        XCTAssertEqual(shown(.iPad), apple)
    }

    /// A physical device offers what `appleDeviceRows` and the allowed process
    /// shapes reach (the manifest's `device` targets).
    func testAPhysicalDeviceOffersItsCapabilityRowsAndTheProcessRows() {
        XCTAssertEqual(shown(.physicalApple), ControlsRow.appleDeviceRows.union(ControlsRow.applePhysicalExtraRows))
        XCTAssertFalse(ControlsRow.cleanStatusBar.availability(on: .physicalApple).isVisible)
        XCTAssertFalse(ControlsRow.sound.availability(on: .physicalApple).isVisible)
    }

    /// Measured on a tvOS 27.0 simulator (Apple TV 4K 3rd generation, a private
    /// device set, 2026-10-01): simctl ui appearance / increase_contrast /
    /// content_size answer "Runtime does not support …", status_bar override
    /// "not supported on this platform", pbcopy "Pasteboard is not supported by
    /// this runtime"; Device Hub 27.0's own tvOS panel lists Appearance, Increase
    /// Contrast, Location and Sound.
    func testAppleTVFollowsTheMeasurementsAndDeviceHub() {
        XCTAssertEqual(shown(.appleTV), ControlsRow.appleTVRows)
        for row in [ControlsRow.appearance, .increaseContrast, .location, .sound] {
            XCTAssertTrue(row.availability(on: .appleTV).isVisible, "\(row): Device Hub lists it")
        }
        let measured: [ControlsRow: String] = [
            .textSize: "dynamic text",
            .cleanStatusBar: "Status bar overrides",
        ]
        for (row, text) in measured {
            let reason = row.availability(on: .appleTV).reason
            XCTAssertTrue(reason?.contains(text) == true && reason?.contains("measured") == true, "\(row): \(reason ?? "nil")")
        }
        XCTAssertNotNil(ControlsRow.biometricsMatch.availability(on: .appleTV).reason)
        XCTAssertFalse(ControlsRow.liquidGlass.availability(on: .appleTV).isVisible, "Device Hub's tvOS panel has no such row")
        XCTAssertFalse(ControlsRow.wifi.availability(on: .appleTV).isVisible)
        XCTAssertEqual(ControlsRow.wifi.availability(on: .appleTV), .hidden)
    }

    func testAppleSimulatorFamilyFromPlatformAndProduct() {
        XCTAssertEqual(ControlsFamily.simulator(platform: "iOS", productFamily: "iPhone"), .iPhone)
        XCTAssertEqual(ControlsFamily.simulator(platform: "iOS", productFamily: "iPad"), .iPad)
        XCTAssertEqual(ControlsFamily.simulator(platform: "tvOS", productFamily: "Apple TV"), .appleTV)
        XCTAssertEqual(ControlsFamily.simulator(platform: "watchOS", productFamily: "Apple Watch"), .appleWatch)
        XCTAssertEqual(ControlsFamily.simulator(platform: "visionOS", productFamily: "Apple Vision"), .appleVision)
        XCTAssertEqual(ControlsFamily.simulator(platform: nil, productFamily: nil), .iPhone)
    }

    /// An Apple TV's cards: Appearance and Increase Contrast need devicectl (simctl
    /// cannot change them on tvOS), Location and Sound follow; nothing for the
    /// iOS-only rows; its groups keep only the rows that answered.
    func testAppleTVCardsAndGroups() {
        let t2: (AppleControl) -> AppleControlRoute = { control in
            var kinds = AppleControlsRouting.available(devicectl: true)
            if control == .appearance || control == .increaseContrast { kinds.remove(.simctl) }
            return AppleControlsRouting.route(control, available: kinds)
        }
        XCTAssertEqual(
            appleSimulatorCards(route: t2, colorFilterSupported: true, family: .appleTV),
            [[.appearance, .increaseContrast], [.location], [.sound, .audioOutput, .audioInput]]
        )
        let groups = appleSimulatorGroups(route: t2, supportsBiometrics: true, family: .appleTV)
        XCTAssertEqual(groups.map(\.id), [.languageAndTime, .appConditions])
        XCTAssertEqual(groups[0].rows, [.deviceLanguage, .timeZone])
        XCTAssertEqual(groups[1].rows, [.targetApp, .permissions, .permissionsAccess, .pushNotification, .launchApp, .terminateApp])
        XCTAssertEqual(appleSimulatorPlainRows(route: t2, family: .appleTV), [.resetKeychain, .linkURL])
    }

    /// The same iPhone cards and groups as before for the families that keep every row.
    func testIPhoneCardsAreUnchanged() {
        let t2: (AppleControl) -> AppleControlRoute = {
            AppleControlsRouting.route($0, available: AppleControlsRouting.available(devicectl: true))
        }
        XCTAssertEqual(
            appleSimulatorCards(route: t2, colorFilterSupported: true, family: .iPhone),
            appleSimulatorCards(route: t2, colorFilterSupported: true)
        )
        XCTAssertEqual(
            appleSimulatorCards(route: t2, colorFilterSupported: true, family: .iPad),
            appleSimulatorCards(route: t2, colorFilterSupported: true)
        )
    }

    /// A control none of whose rows a family shows is out of its route.
    func testControlsFollowTheirRows() {
        XCTAssertTrue(ControlsFamily.appleTV.offers(.location))
        XCTAssertFalse(ControlsFamily.appleTV.offers(.statusBar))
        XCTAssertFalse(ControlsFamily.appleTV.offers(.clipboard))
        XCTAssertTrue(ControlsFamily.appleTV.unavailableReason(for: .clipboard)?.contains("Pasteboard") == true)
        XCTAssertNil(ControlsFamily.iPhone.unavailableReason(for: .clipboard))
        for control in AppleControl.allCases {
            XCTAssertEqual(ControlsFamily.appleTV.unavailableReason(for: control) == nil, ControlsFamily.appleTV.offers(control))
        }
    }
}
