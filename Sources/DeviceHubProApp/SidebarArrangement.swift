import Foundation

/// One group of the sidebar list: a header (nil while Show Groups is off)
/// over its rows.
struct SidebarGroup: Identifiable, Equatable {
    /// Stable across refreshes, so a collapsed group stays collapsed.
    let id: String
    let title: String?
    var rows: [SidebarDeviceRow]
}

/// Device Hub's six Sort By orderings and Show Groups, measured live on
/// Device Hub 27.0 (see "Sort By and Show Groups" in the parity audit).
///
/// Every ordering shares one base order, DH's Availability: the connected
/// and running devices first, then the rest by the date each was last used
/// (a device never used counts from its creation), newest first. The other
/// five re-group that list:
/// - Recent: newest use first, grouped by day (Today, Yesterday, then
///   "26 Sep 2026"); a device never used sits last in "Other".
/// - Name: alphabetical, grouped by first letter.
/// - Fidelity: physical devices, then simulators.
/// - Platform: iOS, then tvOS, …
/// - Operating System: platform, then its version, highest first ("iOS 27.0",
///   "iOS 26.5", "tvOS 26.5").
/// Devices whose runtime is missing stay in a trailing "Unavailable" group.
enum SidebarArrangement {
    /// Platform order of the Platform and Operating System groupings: Apple's
    /// families as Xcode lists them, then Android.
    private static let platformOrder = ["iOS", "iPadOS", "watchOS", "tvOS", "visionOS", "Android"]

    static func groups(
        _ rows: [SidebarDeviceRow],
        mode: WindowState.DeviceSortMode,
        showGroups: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [SidebarGroup] {
        let available = rows.filter(\.isAvailable)
        let unavailable = rows.filter { !$0.isAvailable }.sorted(by: availabilityOrder)
        var groups: [SidebarGroup]
        switch mode {
        case .availability:
            groups = [SidebarGroup(id: "available", title: "Available", rows: available.sorted(by: availabilityOrder))]
        case .recent:
            groups = recentGroups(available, now: now, calendar: calendar)
        case .name:
            groups = nameGroups(available)
        case .fidelity:
            let sorted = available.sorted(by: availabilityOrder)
            groups = [
                SidebarGroup(id: "physical", title: "Physical Devices", rows: sorted.filter { !$0.isEmulator }),
                SidebarGroup(id: "simulators", title: "Simulators", rows: sorted.filter(\.isEmulator)),
            ]
        case .platform:
            groups = keyedGroups(available, key: { $0.platformName }) {
                platformRank($0) != platformRank($1) ? platformRank($0) < platformRank($1) : $0 < $1
            }
        case .operatingSystem:
            groups = keyedGroups(available, key: \.osGroupTitle, order: osOrder)
        }
        groups.removeAll { $0.rows.isEmpty }
        if !unavailable.isEmpty {
            groups.append(SidebarGroup(id: "unavailable", title: "Unavailable", rows: unavailable))
        }
        guard !showGroups else { return groups }
        return [SidebarGroup(id: "all", title: nil, rows: groups.flatMap(\.rows))]
    }

    // MARK: - Orders

    /// DH's Availability order (also every group's inner order): a running
    /// device before a stopped one, then the newest activity first.
    static func availabilityOrder(_ a: SidebarDeviceRow, _ b: SidebarDeviceRow) -> Bool {
        if a.isRunning != b.isRunning { return a.isRunning }
        let (x, y) = (a.lastUsed ?? a.addedAt, b.lastUsed ?? b.addedAt)
        if x != y {
            guard let x else { return false }
            guard let y else { return true }
            return x > y
        }
        return byName(a, b)
    }

    static func byName(_ a: SidebarDeviceRow, _ b: SidebarDeviceRow) -> Bool {
        let order = a.title.localizedCaseInsensitiveCompare(b.title)
        if order != .orderedSame { return order == .orderedAscending }
        return "\(a.selection)" < "\(b.selection)"
    }

    private static func platformRank(_ name: String) -> Int {
        platformOrder.firstIndex(of: name) ?? platformOrder.count
    }

    /// Platform, then the version, highest first.
    private static func osOrder(_ a: String, _ b: String) -> Bool {
        let (pa, va) = splitOS(a)
        let (pb, vb) = splitOS(b)
        if pa != pb { return platformRank(pa) < platformRank(pb) }
        return va.compare(vb, options: .numeric) == .orderedDescending
    }

    private static func splitOS(_ title: String) -> (platform: String, version: String) {
        guard let space = title.firstIndex(of: " ") else { return (title, "") }
        return (String(title[..<space]), String(title[title.index(after: space)...]))
    }

    // MARK: - Groupings

    private static func recentGroups(_ rows: [SidebarDeviceRow], now: Date, calendar: Calendar) -> [SidebarGroup] {
        func date(_ row: SidebarDeviceRow) -> Date? { row.lastUsed }
        let sorted = rows.sorted { a, b in
            switch (date(a), date(b)) {
            case let (x?, y?): x != y ? x > y : byName(a, b)
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): byName(a, b)
            }
        }
        var groups: [SidebarGroup] = []
        for row in sorted {
            let (id, title) = dayHeader(date(row), now: now, calendar: calendar)
            if groups.last?.id == id {
                groups[groups.count - 1].rows.append(row)
            } else {
                groups.append(SidebarGroup(id: id, title: title, rows: [row]))
            }
        }
        return groups
    }

    /// "Today", "Yesterday", then the date as "26 Sep 2026" (DH keeps no
    /// weekday names: a device used three days ago reads "26 Sep 2026").
    static func dayHeader(_ date: Date?, now: Date, calendar: Calendar) -> (id: String, title: String) {
        guard let date else { return ("day-other", "Other") }
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let id = "day-\(Int(day.timeIntervalSince1970))"
        if day == today { return (id, "Today") }
        if calendar.date(byAdding: .day, value: -1, to: today) == day { return (id, "Yesterday") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d MMM yyyy"
        return (id, formatter.string(from: date))
    }

    private static func nameGroups(_ rows: [SidebarDeviceRow]) -> [SidebarGroup] {
        func letter(_ row: SidebarDeviceRow) -> String {
            guard let first = row.title.first else { return "#" }
            let s = String(first).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).uppercased()
            return s.first?.isLetter == true ? s : "#"
        }
        let sorted = rows.sorted(by: byName)
        var groups: [SidebarGroup] = []
        for row in sorted {
            let key = letter(row)
            if groups.last?.id == "letter-\(key)" {
                groups[groups.count - 1].rows.append(row)
            } else {
                groups.append(SidebarGroup(id: "letter-\(key)", title: key, rows: [row]))
            }
        }
        return groups
    }

    private static func keyedGroups(
        _ rows: [SidebarDeviceRow],
        key: (SidebarDeviceRow) -> String,
        order: (String, String) -> Bool
    ) -> [SidebarGroup] {
        let sorted = rows.sorted(by: availabilityOrder)
        var byKey: [String: [SidebarDeviceRow]] = [:]
        for row in sorted { byKey[key(row), default: []].append(row) }
        return byKey.keys.sorted(by: order).map {
            SidebarGroup(id: "key-\($0)", title: $0, rows: byKey[$0] ?? [])
        }
    }
}
