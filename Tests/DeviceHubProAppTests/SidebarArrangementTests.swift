import XCTest
@testable import DeviceHubProApp

/// Device Hub's Sort By orderings and Show Groups. The rows are the ones
/// Device Hub 27.0 listed on the measuring Mac (2026-09-29, `simctl list -j
/// devices` gave each simulator's `lastUsedAt`); each expected order is the
/// one DH showed for that entry.
final class SidebarArrangementTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    /// 2026-09-29 18:13 local (UTC+3).
    private var now: Date { date("2026-09-29T15:13:46Z") }

    private func sim(
        _ title: String, _ platformName: String, _ version: String, used: String?, running: Bool = false,
        created: String? = nil, available: Bool = true
    ) -> SidebarDeviceRow {
        SidebarDeviceRow(
            selection: .simulator("\(title)-\(version)"),
            title: title,
            subtitle: "Simulator",
            version: version,
            isRunning: running,
            symbol: "smartphone",
            isEmulator: true,
            platform: .apple,
            isAvailable: available,
            platformName: platformName,
            lastUsed: used.map(date),
            addedAt: created.map(date)
        )
    }

    private var phone: SidebarDeviceRow {
        SidebarDeviceRow(
            selection: .physicalApple("phone"),
            title: "Eski iPhone’u",
            subtitle: "iPhone 12",
            version: "27.0",
            isRunning: true,
            symbol: "smartphone",
            isEmulator: false,
            platform: .apple,
            platformName: "iOS",
            lastUsed: now
        )
    }

    /// DH's list, in an order that is not any sort's.
    private var rows: [SidebarDeviceRow] {
        [
            sim("iPad Air 11-inch (M4)", "iOS", "26.5", used: "2026-07-10T22:36:04Z"),
            sim("iPhone 17e", "iOS", "26.5", used: "2026-08-13T12:01:29Z"),
            sim("Apple TV", "tvOS", "26.5", used: "2026-09-12T11:42:13Z"),
            sim("iPhone 17", "iOS", "26.5", used: "2026-09-28T16:18:29Z", running: true),
            phone,
            sim("DeviceHubPro-UI-reports", "iOS", "27.0", used: "2026-09-26T17:38:41Z"),
            sim("iPhone 11", "iOS", "26.5", used: "2026-09-18T16:17:24Z"),
            sim("Apple TV 4K (3rd generation)", "tvOS", "26.5", used: "2026-09-15T10:10:12Z"),
            sim("iPhone 17 Pro Max", "iOS", "26.5", used: "2026-09-28T15:38:33Z", running: true),
            sim("iPad (A16)", "iOS", "26.5", used: "2026-08-30T20:56:58Z"),
        ]
    }

    private func arranged(
        _ mode: WindowState.DeviceSortMode, groups: Bool = true, rows: [SidebarDeviceRow]? = nil
    ) -> [SidebarGroup] {
        SidebarArrangement.groups(rows ?? self.rows, mode: mode, showGroups: groups, now: now, calendar: calendar)
    }

    private func titles(_ groups: [SidebarGroup]) -> [String?] { groups.map(\.title) }
    private func names(_ group: SidebarGroup) -> [String] { group.rows.map(\.title) }

    func testAvailabilityListsTheConnectedAndRunningFirstThenTheNewestUse() {
        let groups = arranged(.availability)
        XCTAssertEqual(titles(groups), ["Available"])
        XCTAssertEqual(names(groups[0]), [
            "Eski iPhone’u", "iPhone 17", "iPhone 17 Pro Max", "DeviceHubPro-UI-reports", "iPhone 11",
            "Apple TV 4K (3rd generation)", "Apple TV", "iPad (A16)", "iPhone 17e", "iPad Air 11-inch (M4)",
        ])
    }

    /// DH listed a simulator created after the last boot of a stopped one
    /// (never booted) between the running ones and the older simulators.
    func testAnUnusedSimulatorIsListedByItsCreationInAvailability() {
        let fresh = sim("Fresh", "iOS", "26.5", used: nil, created: "2026-09-29T15:14:00Z")
        let old = sim("Old", "iOS", "26.5", used: "2026-09-26T17:38:41Z")
        let running = sim("Running", "iOS", "26.5", used: "2026-09-01T00:00:00Z", running: true)
        let groups = arranged(.availability, rows: [old, fresh, running])
        XCTAssertEqual(names(groups[0]), ["Running", "Fresh", "Old"])
    }

    func testRecentGroupsByDayNewestFirst() {
        let groups = arranged(.recent)
        XCTAssertEqual(titles(groups), [
            "Today", "Yesterday", "26 Sep 2026", "18 Sep 2026", "15 Sep 2026", "12 Sep 2026",
            "30 Aug 2026", "13 Aug 2026", "11 Jul 2026",
        ])
        XCTAssertEqual(names(groups[0]), ["Eski iPhone’u"])
        XCTAssertEqual(names(groups[1]), ["iPhone 17", "iPhone 17 Pro Max"])
    }

    func testRecentPutsADeviceNeverUsedLastInOther() {
        let never = sim("Never", "iOS", "26.5", used: nil, created: "2026-09-29T15:14:00Z")
        let groups = arranged(.recent, rows: rows + [never])
        XCTAssertEqual(groups.last?.title, "Other")
        XCTAssertEqual(names(groups.last!), ["Never"])
    }

    /// A day boundary is the local one: 2026-09-28 22:00Z is already Sep 29
    /// in Istanbul.
    func testADayIsTheLocalDay() {
        let late = sim("Late", "iOS", "26.5", used: "2026-09-28T22:00:00Z")
        XCTAssertEqual(titles(arranged(.recent, rows: [late])), ["Today"])
    }

    func testNameIsAlphabeticalWithLetterGroups() {
        let groups = arranged(.name)
        XCTAssertEqual(titles(groups), ["A", "D", "E", "I"])
        XCTAssertEqual(names(groups[0]), ["Apple TV", "Apple TV 4K (3rd generation)"])
        XCTAssertEqual(names(groups[1]), ["DeviceHubPro-UI-reports"])
        XCTAssertEqual(names(groups[3]), [
            "iPad (A16)", "iPad Air 11-inch (M4)", "iPhone 11", "iPhone 17", "iPhone 17 Pro Max", "iPhone 17e",
        ])
    }

    func testFidelityListsPhysicalDevicesBeforeSimulators() {
        let groups = arranged(.fidelity)
        XCTAssertEqual(titles(groups), ["Physical Devices", "Simulators"])
        XCTAssertEqual(names(groups[0]), ["Eski iPhone’u"])
        XCTAssertEqual(groups[1].rows.count, 9)
        XCTAssertEqual(groups[1].rows.first?.title, "iPhone 17")
    }

    func testPlatformGroupsIOSBeforeTvOSKeepingTheAvailabilityOrderInside() {
        let groups = arranged(.platform)
        XCTAssertEqual(titles(groups), ["iOS", "tvOS"])
        XCTAssertEqual(names(groups[0]), [
            "Eski iPhone’u", "iPhone 17", "iPhone 17 Pro Max", "DeviceHubPro-UI-reports", "iPhone 11",
            "iPad (A16)", "iPhone 17e", "iPad Air 11-inch (M4)",
        ])
        XCTAssertEqual(names(groups[1]), ["Apple TV 4K (3rd generation)", "Apple TV"])
    }

    func testOperatingSystemGroupsThePlatformThenTheHighestVersionFirst() {
        let groups = arranged(.operatingSystem)
        XCTAssertEqual(titles(groups), ["iOS 27.0", "iOS 26.5", "tvOS 26.5"])
        XCTAssertEqual(names(groups[0]), ["Eski iPhone’u", "DeviceHubPro-UI-reports"])
        XCTAssertEqual(names(groups[1]).first, "iPhone 17")
    }

    func testAVersionIsComparedAsANumber() {
        let a = sim("A", "iOS", "9.3", used: nil)
        let b = sim("B", "iOS", "18.0", used: nil)
        XCTAssertEqual(titles(arranged(.operatingSystem, rows: [a, b])), ["iOS 18.0", "iOS 9.3"])
    }

    func testAndroidGroupsComeAfterApple() {
        let android = SidebarDeviceRow(
            selection: .avd("Pixel"), title: "Pixel", subtitle: "Emulator", version: "15", isRunning: true,
            symbol: "smartphone", isEmulator: true, platform: .android, lastUsed: now
        )
        XCTAssertEqual(titles(arranged(.platform, rows: [android] + rows)), ["iOS", "tvOS", "Android"])
        XCTAssertEqual(titles(arranged(.operatingSystem, rows: [android] + rows)).last, "Android 15")
    }

    func testShowGroupsOffIsOneFlatListInTheSameOrder() {
        for mode in WindowState.DeviceSortMode.allCases {
            let grouped = arranged(mode).flatMap(\.rows).map(\.title)
            let flat = arranged(mode, groups: false)
            XCTAssertEqual(flat.count, 1, "\(mode)")
            XCTAssertNil(flat[0].title)
            XCTAssertEqual(flat[0].rows.map(\.title), grouped, "\(mode)")
        }
    }

    func testAnUnavailableSimulatorStaysInATrailingGroupInEveryMode() {
        let missing = sim("Missing", "watchOS", "11.0", used: nil, available: false)
        for mode in WindowState.DeviceSortMode.allCases {
            let groups = arranged(mode, rows: rows + [missing])
            XCTAssertEqual(groups.last?.title, "Unavailable", "\(mode)")
            XCTAssertEqual(groups.last?.rows.map(\.title), ["Missing"], "\(mode)")
        }
    }

    func testTheMenusListTheSixEntriesInDeviceHubsOrderAndNames() {
        XCTAssertEqual(
            WindowState.DeviceSortMode.allCases.map(\.title),
            ["Availability", "Recent", "Name", "Fidelity", "Platform", "Operating System"]
        )
    }
}

/// The glass depth profiles (`GlassDepthProfile`): measured stops, so they
/// must run top to bottom, start and end on the white rim, and stay in range.
final class GlassDepthProfileTests: XCTestCase {
    func testTheStopsRunTopToBottomBetweenTheRims() {
        for profile in [GlassDepthProfile.raised, .recessed] {
            let locations = profile.stops.map(\.at)
            XCTAssertEqual(locations.first, 0)
            XCTAssertEqual(locations.last, 1)
            XCTAssertEqual(locations, locations.sorted())
            XCTAssertEqual(profile.stops.first?.alpha, 1, "white rim on the top edge")
            XCTAssertEqual(profile.stops.last?.alpha, 1, "white rim on the bottom edge")
            XCTAssertTrue(profile.stops.allSatisfy { (-1...1).contains($0.alpha) })
        }
    }

    /// A raised capsule is lighter than the bar in the middle (Device Hub's
    /// #f1-#f5 over #ed); the search field is not raised there.
    func testTheRaisedCapsuleIsLighterAtTheMiddleThanTheSearchField() {
        func alpha(_ profile: GlassDepthProfile, at fraction: Double) -> Double {
            profile.stops.min { abs($0.at - fraction) < abs($1.at - fraction) }?.alpha ?? 0
        }
        XCTAssertGreaterThan(alpha(.raised, at: 0.5), 0.3)
        XCTAssertLessThanOrEqual(alpha(.recessed, at: 0.5), 0)
    }
}
