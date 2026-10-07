import XCTest
@testable import DeviceHubProApp

/// The second stage / inspector parity pass (2026-09-29): Edit Visibility's
/// properties, the settings tooltips, the info row's truncation rule.
final class StageRound2Tests: XCTestCase {
    // MARK: - Edit Visibility (measured on DH 27.0)

    func testTheDefaultVisibleInfoPropertiesAreDeviceHubs() {
        XCTAssertEqual(
            SimulatorInfoProperty.defaultVisible,
            [.name, .os, .model, .productType, .udid, .display]
        )
    }

    func testTheChecklistHasDeviceHubsFiveSectionsInOrder() {
        XCTAssertEqual(
            SimulatorInfoProperty.Section.allCases.map(\.title),
            ["Essential Properties", "Device Properties", "Hardware Properties", "Connection Properties", "Device Configuration"]
        )
        XCTAssertEqual(SimulatorInfoProperty.Section.essential.properties.map(\.title), ["Name", "OS", "CoreDevice ID"])
        XCTAssertEqual(SimulatorInfoProperty.Section.device.properties.map(\.title), ["Boot State", "DDI Services"])
        XCTAssertEqual(
            SimulatorInfoProperty.Section.hardware.properties.map(\.title),
            ["CPU Type", "Model", "Platform", "Product Type", "Fidelity", "UDID"]
        )
        XCTAssertEqual(
            SimulatorInfoProperty.Section.connection.properties.map(\.title),
            ["Last Connection Date", "Pairing State", "Transport Type", "Tunnel State"]
        )
        XCTAssertEqual(SimulatorInfoProperty.Section.displays.properties.map(\.title), ["Display"])
        XCTAssertEqual(SimulatorInfoProperty.Section.displays.subtitle, "Displays")
    }

    func testTheChoiceRoundTripsAndIgnoresUnknownNames() {
        let visible: Set<SimulatorInfoProperty> = [.name, .cpuType, .tunnelState]
        XCTAssertEqual(SimulatorInfoProperty.decode(SimulatorInfoProperty.encode(visible)), visible)
        XCTAssertEqual(SimulatorInfoProperty.decode(nil), SimulatorInfoProperty.defaultVisible)
        XCTAssertEqual(SimulatorInfoProperty.decode(["name", "fromTheFuture"]), [.name])
        XCTAssertEqual(SimulatorInfoProperty.decode([]), [], "everything unticked is a choice too")
    }

    private func values(booted: Bool, lastUsed: Date? = nil) -> SimulatorInfoValues {
        SimulatorInfoValues(
            name: "iPhone 17", os: "iOS 26.5", udid: "41D6888A-0FA0-44B7-A8CD-5617FB54FFFB",
            isBooted: booted, model: "iPhone 17", productType: "iPhone18,3", platform: "iOS",
            display: "1206 × 2622", lastUsed: lastUsed, cpuType: "arm64"
        )
    }

    func testTheDefaultCardsAreDeviceHubsInfoTab() {
        let cards = values(booted: true).cards(visible: SimulatorInfoProperty.defaultVisible)
        XCTAssertEqual(cards.map { $0.map(\.property) }, [[.name, .os], [.model, .productType, .udid], [.display]])
    }

    func testAnEmptySectionLeavesNoCardAndTicksRegroupBySection() {
        let cards = values(booted: true).cards(visible: [.bootState, .cpuType, .tunnelState])
        XCTAssertEqual(cards.map { $0.map(\.property) }, [[.bootState], [.cpuType], [.tunnelState]])
        XCTAssertTrue(values(booted: true).cards(visible: []).isEmpty)
    }

    func testTheValuesAreDeviceHubsWordsForBothStates() {
        let running = values(booted: true)
        XCTAssertEqual(running.value(of: .bootState), "Booted")
        XCTAssertEqual(running.value(of: .ddiServices), "Enabled")
        XCTAssertEqual(running.value(of: .tunnelState), "Connected")
        let stopped = values(booted: false)
        XCTAssertEqual(stopped.value(of: .bootState), "ShutDown")
        XCTAssertEqual(stopped.value(of: .ddiServices), "Disabled")
        XCTAssertEqual(stopped.value(of: .tunnelState), "Disconnected")
        XCTAssertEqual(stopped.value(of: .fidelity), "Simulated")
        XCTAssertEqual(stopped.value(of: .pairingState), "Paired")
        XCTAssertEqual(stopped.value(of: .transportType), "Same Machine")
        XCTAssertEqual(stopped.value(of: .coreDeviceID), stopped.udid)
    }

    func testALastConnectionNeverMadeHasNoRowAndAnUnreadDisplayShowsDashes() {
        var never = values(booted: false)
        never.display = nil
        XCTAssertNil(never.value(of: .lastConnectionDate), "a device never booted has none")
        let cards = never.cards(visible: [.lastConnectionDate, .display])
        XCTAssertEqual(cards.map { $0.map(\.property) }, [[.display]])
        XCTAssertEqual(cards.first?.first?.value, "--")
        let used = values(booted: true, lastUsed: Date(timeIntervalSince1970: 0))
        XCTAssertNotNil(used.value(of: .lastConnectionDate, formatter: { "\($0.timeIntervalSince1970)" }))
    }

    @MainActor
    func testTheChoiceIsPersisted() {
        let defaults = UserDefaults.scratch()
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.simulatorInfoVisible, SimulatorInfoProperty.defaultVisible)
        preferences.setSimulatorInfoVisible([.name, .cpuType])
        XCTAssertEqual(AppPreferences(defaults: defaults).simulatorInfoVisible, [.name, .cpuType])
    }

    // MARK: - Tooltips

    func testNoTooltipQuotesACommandLine() {
        for text in [
            "devicectl device settings appearance --reduce-motion on|off, read back with devicectl device info appearance.",
            "simctl ui increase_contrast enabled|disabled.",
            "Runs svc wifi enable|disable.",
            "Runs cmd connectivity airplane-mode enable|disable.",
            "Writes settings put system font_scale.",
            "Reads it back from dumpsys connectivity.",
            "Writes secure high_text_contrast_enabled.",
            "The emulator's network delay (adb emu network delay).",
            "-e command battery -e level N",
        ] {
            XCTAssertEqual(DHHelp.tooltip(text), "", text)
        }
    }

    func testAShortPlainTooltipIsKeptUnlessThePanelShowsNone() {
        let text = "Turns Wi-Fi on or off, like Settings does."
        XCTAssertEqual(DHHelp.tooltip(text), text)
        XCTAssertEqual(DHHelp.tooltip(text, enabled: false), "")
        XCTAssertEqual(DHHelp.tooltip(""), "")
        XCTAssertEqual(DHHelp.tooltip(String(repeating: "word ", count: 40)), "", "too long to be a hint")
    }

    // MARK: - Info rows

    func testTheLongerOfLabelAndValueGivesWay() {
        typealias Layout = InfoTwoColumnLayout
        // Both fit: both whole.
        XCTAssertTrue(Layout.widths(label: 40, value: 60, available: 200) == (40, 60))
        // A long value (a UDID) is cut and the label stays whole.
        let udid = Layout.widths(label: 40, value: 300, available: 200)
        XCTAssertEqual(udid.0, 40)
        XCTAssertEqual(udid.1, 200 - Layout.gap - 40)
        // A long label ("Last Connection Date") is cut and the date stays whole.
        let date = Layout.widths(label: 133, value: 108, available: 230)
        XCTAssertEqual(date.1, 108)
        XCTAssertEqual(date.0, 230 - Layout.gap - 108)
    }
}
