import Foundation

// MARK: - Mechanism

/// SystemUI's demo mode: the same keys and sequence as Developer options ▸
/// System UI demo mode (`DemoModeFragment.startDemoMode`, android-17.0.0_r1
/// L155–200). Device Hub Pro writes `sysui_demo_allowed` = 1 (the gate) and waits
/// until SystemUI reports it, writes `sysui_tuner_demo_on` = 1, then sends
/// `am broadcast -a com.android.systemui.demo -e command …` commands. It never
/// sends an `enter` broadcast: on API 31+ the tuner write enters demo mode, on
/// every API the first command does, and an explicit `enter` on top of the
/// tuner calls every receiver's `onDemoModeStarted` twice
/// (`DemoModeController.kt`@17 L196–197). SystemUI registers no `cmd` for demo
/// mode (`CommandRegistry`@17).
///
/// `am broadcast` answers `Broadcast completed: result=0` whether SystemUI took
/// the command or ignored it, and delivery trails that answer, so every write
/// is read back (`StatusBarDemoSnapshot`): `dumpsys activity service
/// com.android.systemui/.SystemUIService DemoModeController` from API 31 and
/// `… BatteryController` from API 33. The clock, Wi-Fi and mobile icons have no
/// readback on any version: the stage shows them.
public enum StatusBarDemo {
    public static let action = "com.android.systemui.demo"
    /// `DemoModeController.DEMO_MODE_ALLOWED` (global, `getInt != 0`).
    public static let allowedKey = "sysui_demo_allowed"
    /// `DemoModeController.DEMO_MODE_ON` (global).
    public static let onKey = "sysui_tuner_demo_on"
    public static let systemUIService = "com.android.systemui/.SystemUIService"
    /// Demo mode since android-6.0.1_r81 (`PhoneStatusBar.java` L932–938).
    public static let minimumAPI = 23
    /// `DemoModeController`: the dumpable and the tuner-key observer
    /// (android-12.0.0_r34).
    public static let controllerMinimumAPI = 31
    /// `BatteryController` becomes a dumpable (android-13.0.0_r84 L154).
    public static let batteryReadbackMinimumAPI = 33
    /// `battery -e powersave` (Android 8.1): `BatteryControllerImpl.java`
    /// @android-8.1.0_r1 L212 reads it; @android-8.0.0_r1 L209–216 reads
    /// only `level` and `plugged`.
    public static let powerSaveMinimumAPI = 27
    /// `network -e datatype 5g` (Android 11).
    public static let fiveGMinimumAPI = 30
    /// From API 34 the demo mobile icon is drawn from the real connection:
    /// `MobileIconsInteractorImpl.reuseCache` hands the demo repository's
    /// `DEFAULT_SUB_ID = 1` the interactor cached for the real SIM, and its
    /// numeric lookup key falls back to `THREE_G` (`MobileIconsInteractor.kt`
    /// @14.0.0_r75 L374–391 … @17 L448–466, `MobileIconInteractor.kt`@17
    /// L218). Measured on API 37: the real bars and a 3G label.
    public static let mobileDemoMaximumAPI = 33
    /// With neither a Wi-Fi nor a mobile icon, Android 15+ draws a satellite
    /// icon (`DemoDeviceBasedSatelliteDataSource.kt`@15.0.0_r36).
    public static let satelliteIconMinimumAPI = 35
    /// The Screenshot preset's clock: neutral, and not Apple's 9:41.
    public static let screenshotClock = DemoClockTime(hour: 9, minute: 41)!
}

// MARK: - Values

/// A demo clock time, `clock -e hhmm HHMM`. SystemUI sets `HOUR_OF_DAY` in
/// 24-hour format and `HOUR` leniently in 12-hour format, so 13:30 shows as
/// 1:30 there (`Clock.java`@17 L446–465).
public struct DemoClockTime: Sendable, Hashable, Identifiable {
    public let hour: Int
    public let minute: Int

    public init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    /// `9:41`, `09:41` or `0941`, blanks trimmed.
    public init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func number(_ digits: Substring) -> Int? {
            guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
            return Int(digits)
        }
        let hourText: Substring
        let minuteText: Substring
        if let colon = trimmed.firstIndex(of: ":") {
            hourText = trimmed[..<colon]
            minuteText = trimmed[trimmed.index(after: colon)...]
            guard (1...2).contains(hourText.count), minuteText.count == 2 else { return nil }
        } else {
            guard trimmed.count == 4 else { return nil }
            hourText = trimmed.prefix(2)
            minuteText = trimmed.suffix(2)
        }
        guard let hour = number(hourText), let minute = number(minuteText) else { return nil }
        self.init(hour: hour, minute: minute)
    }

    /// The `-e hhmm` value: `0941`.
    public var hhmm: String { String(format: "%02d%02d", hour, minute) }
    /// `9:41`, `12:00`.
    public var label: String { "\(hour):" + String(format: "%02d", minute) }
    public var id: String { hhmm }

}

/// The demo Wi-Fi icon: `network -e wifi show -e level N -e fully true` (drawn
/// connected and validated; without `fully` the new pipeline adds an
/// exclamation mark), or `-e wifi hide`.
public enum WifiDemoIcon: Sendable, Hashable, Identifiable {
    /// 1…4 bars.
    case bars(Int)
    case hidden

    public static let options: [WifiDemoIcon] = [.bars(4), .bars(3), .bars(2), .bars(1), .hidden]

    public var id: String {
        switch self {
        case .bars(let level): return "bars-\(level)"
        case .hidden: return "hidden"
        }
    }

    public var label: String {
        switch self {
        case .bars(4): return "4 bars (full)"
        case .bars(1): return "1 bar"
        case .bars(let level): return "\(level) bars"
        case .hidden: return "Hidden"
        }
    }
}

public enum MobileDemoDataType: String, Sendable, Hashable {
    case lte
    case fiveG = "5g"

    public var label: String {
        switch self {
        case .lte: return "LTE"
        case .fiveG: return "5G"
        }
    }
}

/// The demo mobile icon, API 33 and older only (`StatusBarDemo.mobileDemoMaximumAPI`).
public enum MobileDemoIcon: Sendable, Hashable, Identifiable {
    /// 0…4 bars.
    case signal(level: Int, dataType: MobileDemoDataType)
    case hidden

    /// API 33 and older: full and two-bar LTE, full 5G from API 30, no signal
    /// and hidden. From API 34 only Hidden: the demo icon shows the real
    /// connection there.
    public static func options(apiLevel: Int?) -> [MobileDemoIcon] {
        let api = apiLevel ?? 0
        guard api <= StatusBarDemo.mobileDemoMaximumAPI else { return [.hidden] }
        var options: [MobileDemoIcon] = [.signal(level: 4, dataType: .lte), .signal(level: 2, dataType: .lte)]
        if api >= StatusBarDemo.fiveGMinimumAPI {
            options.append(.signal(level: 4, dataType: .fiveG))
        }
        options += [.signal(level: 0, dataType: .lte), .hidden]
        return options
    }

    public var id: String {
        switch self {
        case .signal(let level, let dataType): return "\(dataType.rawValue)-\(level)"
        case .hidden: return "hidden"
        }
    }

    public var label: String {
        switch self {
        case .signal(0, _): return "No signal"
        case .signal(4, let dataType): return "Full · \(dataType.label)"
        case .signal(1, let dataType): return "1 bar · \(dataType.label)"
        case .signal(let level, let dataType): return "\(level) bars · \(dataType.label)"
        case .hidden: return "Hidden"
        }
    }
}

/// The demo battery's state: `-e plugged` and `-e powersave`.
public enum BatteryDemoState: String, CaseIterable, Sendable, Identifiable {
    case notCharging
    case charging
    case batterySaver

    public var id: String { rawValue }
    public var plugged: Bool { self == .charging }
    public var powerSave: Bool { self == .batterySaver }

    public var label: String {
        switch self {
        case .notCharging: return "Not charging"
        case .charging: return "Charging"
        case .batterySaver: return "Battery saver"
        }
    }

    /// Battery saver needs `-e powersave` (API 27+).
    public static func options(apiLevel: Int?) -> [BatteryDemoState] {
        (apiLevel ?? 0) >= StatusBarDemo.powerSaveMinimumAPI ? allCases : [.notCharging, .charging]
    }

    /// The state a `plugged` / `powersave` pair shows; nil for both at once.
    public static func from(plugged: Bool, powerSave: Bool) -> BatteryDemoState? {
        switch (plugged, powerSave) {
        case (false, false): return .notCharging
        case (true, false): return .charging
        case (false, true): return .batterySaver
        case (true, true): return nil
        }
    }
}

// MARK: - Commands

/// One demo broadcast. Every value is an integer or an enum, so no device
/// text ever reaches a script.
public enum DemoCommand: Sendable, Hashable {
    /// Only for tests (another tool's demo mode): Device Hub Pro never sends it.
    case enter
    case exit
    case clock(DemoClockTime)
    /// `level` is clamped 0–100 by SystemUI; a nil `plugged` or `powerSave`
    /// is left out of the command.
    case battery(level: Int, plugged: Bool?, powerSave: Bool?)
    case wifi(WifiDemoIcon)
    /// The show form is SOURCE-DERIVED from `NetworkControllerImpl`
    /// (android-11.0.0_r48) and sent only on API 33 and older.
    case mobile(MobileDemoIcon)
    case notifications(visible: Bool)

    /// `am broadcast -a com.android.systemui.demo -e command …`.
    public var shellCommand: String {
        "am broadcast -a \(StatusBarDemo.action) -e command " + commandArguments
    }

    private var commandArguments: String {
        switch self {
        case .enter:
            return "enter"
        case .exit:
            return "exit"
        case .clock(let time):
            return "clock -e hhmm \(time.hhmm)"
        case .battery(let level, let plugged, let powerSave):
            var text = "battery -e level \(level)"
            if let plugged { text += " -e plugged \(plugged)" }
            if let powerSave { text += " -e powersave \(powerSave)" }
            return text
        case .wifi(.bars(let level)):
            return "network -e wifi show -e level \(level) -e fully true"
        case .wifi(.hidden):
            return "network -e wifi hide"
        case .mobile(.signal(let level, let dataType)):
            return "network -e mobile show -e datatype \(dataType.rawValue) -e level \(level) -e fully true"
        case .mobile(.hidden):
            return "network -e mobile hide"
        case .notifications(let visible):
            return "notifications -e visible \(visible)"
        }
    }

    /// The battery SystemUI should show after this command, for the read-back;
    /// nil for the other commands.
    var expectedBattery: DemoBatteryReading? {
        guard case .battery(let level, let plugged, let powerSave) = self else { return nil }
        return DemoBatteryReading(level: min(max(level, 0), 100), pluggedIn: plugged ?? false, powerSave: powerSave)
    }

    /// Whether SystemUI's battery shows this command's values; the values it
    /// left out match anything.
    func batteryApplied(_ shown: DemoBatteryReading) -> Bool {
        guard case .battery(let level, let plugged, let powerSave) = self else { return true }
        return shown.level == min(max(level, 0), 100)
            && (plugged.map { $0 == shown.pluggedIn } ?? true)
            && (powerSave.map { $0 == (shown.powerSave ?? false) } ?? true)
    }
}

/// The shell scripts behind the Status bar rows, one `adb shell` line each.
public enum StatusBarDemoScript {
    /// The tuner key, then the commands: on API 31+ the key enters demo mode
    /// (SystemUI watches it), on every API the first command does.
    public static func enter(_ commands: [DemoCommand]) -> String {
        precondition(!commands.isEmpty, "entering demo mode needs at least one command")
        return (["settings put global \(StatusBarDemo.onKey) 1"] + commands.map(\.shellCommand) + ["true"])
            .joined(separator: "; ")
    }

    public static func send(_ commands: [DemoCommand]) -> String {
        (commands.map(\.shellCommand) + ["true"]).joined(separator: "; ")
    }

    /// An unset key is deleted again. Anything else comes back as 0: a
    /// nonzero value without demo mode exists only on API 30 and older, where
    /// SystemUI ignores the key, and writing 1 on API 31+ would enter demo
    /// mode.
    public static func tunerRestore(_ original: StatusBarDemoOriginal) -> String {
        original.onRaw == nil
            ? "settings delete global \(StatusBarDemo.onKey)"
            : "settings put global \(StatusBarDemo.onKey) 0"
    }

    /// Nothing when the gate was already allowed; the raw value otherwise
    /// (quoted: it is the only device text in any script).
    public static func allowedRestore(_ original: StatusBarDemoOriginal) -> String? {
        guard let raw = original.allowedRaw else { return "settings delete global \(StatusBarDemo.allowedKey)" }
        if let value = Int(raw), value != 0 { return nil }
        return "settings put global \(StatusBarDemo.allowedKey) " + AdbClient.shellQuoted(raw)
    }

    /// Ends demo mode and puts the keys back: the gate first when SystemUI
    /// ignores commands (`forceAllow`), the real battery as a demo command
    /// (API 30+ re-register the battery receiver through BroadcastDispatcher
    /// with no sticky replay, so the demo level would stay; measured on API
    /// 37), `exit`, then the keys.
    public static func exit(
        forceAllow: Bool,
        realBattery: RealBatteryReading?,
        original: StatusBarDemoOriginal
    ) -> String {
        let parts: [String?] = [
            forceAllow ? "settings put global \(StatusBarDemo.allowedKey) 1" : nil,
            realBattery.map { DemoCommand.battery(level: $0.percent, plugged: $0.isPowered, powerSave: nil).shellCommand },
            DemoCommand.exit.shellCommand,
            tunerRestore(original),
            allowedRestore(original),
            "true",
        ]
        return parts.compactMap { $0 }.joined(separator: "; ")
    }

    /// The keys alone, no broadcast.
    public static func restoreKeys(original: StatusBarDemoOriginal) -> String {
        [tunerRestore(original), allowedRestore(original), "true"].compactMap { $0 }.joined(separator: "; ")
    }

    /// The put-back for what SystemUI reports now:
    /// - in demo mode: the full exit, allowing first when the gate is off;
    /// - not in demo mode, with SystemUI's battery left on a demo value
    ///   (`batteryNeedsRealign`): the full exit too, so the `battery` realign
    ///   (which enters demo mode on the way) is followed by `exit`; demo mode
    ///   ended elsewhere leaves the demo value (`BatteryControllerImpl.java`
    ///   @android-17.0.0_r1 L556–564 re-registers with no sticky replay);
    /// - not in demo mode otherwise: the keys alone (a realign would enter
    ///   demo mode while the gate is 1);
    /// - no report (API 30 and older, or a SystemUI without the dumpable):
    ///   the full exit without the gate. Android 11 needs the realign as 12+
    ///   do (SOURCE-DERIVED: android-11.0.0_r48 `BatteryControllerImpl.java`
    ///   L99–104 and L358–361 re-register through BroadcastDispatcher, which
    ///   `KeyguardUpdateMonitor.java` L1705–1713 keeps registered for
    ///   ACTION_BATTERY_CHANGED, so there is no sticky replay; Android 10
    ///   registers with the context, which replays it). Out of demo mode the
    ///   battery command enters it on the way and `exit` ends it
    ///   (`StatusBar.java`@11 L3096–3124); with the gate off both are ignored.
    ///
    /// `realignBattery`: realign out of demo mode where SystemUI does not
    /// report its battery (API 31–32): Device Hub Pro's demo mode ended elsewhere.
    public static func restore(
        for snapshot: StatusBarDemoSnapshot,
        original: StatusBarDemoOriginal,
        realignBattery: Bool = false
    ) -> String {
        guard let controller = snapshot.controller else {
            return exit(forceAllow: false, realBattery: snapshot.realBattery, original: original)
        }
        guard controller.isInDemoMode || snapshot.batteryNeedsRealign(whenUnread: realignBattery) else {
            return restoreKeys(original: original)
        }
        return exit(forceAllow: !controller.isAllowed, realBattery: snapshot.realBattery, original: original)
    }

    /// Whether `restore(for:…)` needs the gate open before its broadcasts,
    /// which SystemUI ignores otherwise: in demo mode with the gate off (the
    /// stuck state), or a realign out of demo mode with the gate off.
    public static func needsGate(for snapshot: StatusBarDemoSnapshot, realignBattery: Bool = false) -> Bool {
        guard let controller = snapshot.controller, !controller.isAllowed else { return false }
        return controller.isInDemoMode || snapshot.batteryNeedsRealign(whenUnread: realignBattery)
    }
}

/// The Preset row's presets. The battery command comes last: broadcasts
/// reach SystemUI in order, so its read-back on API 33+ shows the whole
/// script was processed.
public enum StatusBarPreset: String, CaseIterable, Identifiable, Sendable {
    case screenshot
    case lowBattery
    case charging

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .screenshot: return "Screenshot"
        case .lowBattery: return "Low battery"
        case .charging: return "Charging"
        }
    }

    public func commands(apiLevel: Int?, handlesNotifications: Bool) -> [DemoCommand] {
        let api = apiLevel ?? 0
        func mobile(_ level: Int) -> DemoCommand {
            api <= StatusBarDemo.mobileDemoMaximumAPI
                ? .mobile(.signal(level: level, dataType: .lte))
                : .mobile(.hidden)
        }
        let powerSave: Bool? = api >= StatusBarDemo.powerSaveMinimumAPI ? false : nil
        switch self {
        case .screenshot:
            return [
                .clock(StatusBarDemo.screenshotClock),
                .wifi(.bars(4)),
                mobile(4),
                .battery(level: 100, plugged: false, powerSave: powerSave),
            ] + (handlesNotifications ? [.notifications(visible: false)] : [])
        case .lowBattery:
            return [.wifi(.bars(1)), mobile(1), .battery(level: 5, plugged: false, powerSave: powerSave)]
        case .charging:
            return [.wifi(.bars(2)), mobile(2), .battery(level: 50, plugged: true, powerSave: powerSave)]
        }
    }
}

// MARK: - Readings

/// `dumpsys activity service com.android.systemui/.SystemUIService
/// DemoModeController` (API 31+): whether SystemUI is in demo mode, whether
/// the gate is open, and which receivers each command reaches.
///
///     isInDemoMode=true
///     isDemoModeAllowed=true
///     notifications : []                      (API 35+: `[A, B]`)
///     notifications : [NotificationIcon… ]    (API 31–34: `[A,B ]`)
public struct DemoModeControllerReading: Sendable, Equatable {
    public var isInDemoMode: Bool
    public var isAllowed: Bool
    /// Command → receiver class names (an anonymous receiver's empty
    /// `simpleName` on API 31 is dropped).
    public var receivers: [String: [String]]

    public init(isInDemoMode: Bool, isAllowed: Bool, receivers: [String: [String]] = [:]) {
        self.isInDemoMode = isInDemoMode
        self.isAllowed = isAllowed
        self.receivers = receivers
    }

    /// Whether any receiver handles `command`; nil when the dump does not list it.
    public func handles(_ command: String) -> Bool? {
        receivers[command].map { !$0.isEmpty }
    }

    /// The grepped probe section or the whole dump; nil without an
    /// `isInDemoMode=` line (an unknown target prints only its header).
    public static func parse(_ text: String) -> DemoModeControllerReading? {
        var inDemoMode: Bool?
        var allowed: Bool?
        var receivers: [String: [String]] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("isInDemoMode=") {
                inDemoMode = Bool(String(line.dropFirst("isInDemoMode=".count)))
            } else if line.hasPrefix("isDemoModeAllowed=") {
                allowed = Bool(String(line.dropFirst("isDemoModeAllowed=".count)))
            } else if let entry = receiverEntry(line) {
                receivers[entry.command] = entry.receivers
            }
        }
        guard let inDemoMode else { return nil }
        return DemoModeControllerReading(isInDemoMode: inDemoMode, isAllowed: allowed ?? false, receivers: receivers)
    }

    /// `^([a-z]+) : \[(.*)\]$` on a trimmed line.
    private static func receiverEntry(_ line: String) -> (command: String, receivers: [String])? {
        guard let separator = line.range(of: " : ["), line.hasSuffix("]") else { return nil }
        let command = line[..<separator.lowerBound]
        guard !command.isEmpty, command.allSatisfy({ ("a"..."z").contains($0) }) else { return nil }
        let body = line[separator.upperBound..<line.index(before: line.endIndex)]
        let names = body.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (String(command), names)
    }
}

/// SystemUI's battery (`dumpsys … BatteryController`, API 33+): what its
/// battery icon draws, demo values included.
public struct DemoBatteryReading: Sendable, Equatable {
    public var level: Int
    public var pluggedIn: Bool
    public var powerSave: Bool?

    public init(level: Int, pluggedIn: Bool, powerSave: Bool?) {
        self.level = level
        self.pluggedIn = pluggedIn
        self.powerSave = powerSave
    }

    /// `50%, charging, battery saver`.
    public var label: String {
        var parts = ["\(level)%", pluggedIn ? "charging" : "not charging"]
        if powerSave == true { parts.append("battery saver") }
        return parts.joined(separator: ", ")
    }

    /// The first `mLevel=`, `mPluggedIn=` and `mPowerSave=`; nil without `mLevel=`.
    public static func parse(_ text: String) -> DemoBatteryReading? {
        var level: Int?
        var plugged: Bool?
        var powerSave: Bool?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if level == nil, line.hasPrefix("mLevel=") {
                level = Int(line.dropFirst("mLevel=".count))
            } else if plugged == nil, line.hasPrefix("mPluggedIn=") {
                plugged = Bool(String(line.dropFirst("mPluggedIn=".count)))
            } else if powerSave == nil, line.hasPrefix("mPowerSave=") {
                powerSave = Bool(String(line.dropFirst("mPowerSave=".count)))
            }
        }
        guard let level else { return nil }
        return DemoBatteryReading(level: level, pluggedIn: plugged ?? false, powerSave: powerSave)
    }
}

/// The real battery (`dumpsys battery`): what apps read, and what the exit
/// puts back on SystemUI's icon.
public struct RealBatteryReading: Sendable, Equatable {
    public var percent: Int
    /// Any charger connected; nil when the dump names none.
    public var isPowered: Bool?

    public init(percent: Int, isPowered: Bool?) {
        self.percent = percent
        self.isPowered = isPowered
    }

    /// `  level: N` and `  scale: M` (percent = level × 100 / scale) and the
    /// `… powered:` lines; the grepped probe section or the whole dump.
    public static func parse(_ text: String) -> RealBatteryReading? {
        var level: Int?
        var scale: Int?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if level == nil, line.hasPrefix("level:") {
                level = Int(line.dropFirst("level:".count).trimmingCharacters(in: .whitespaces))
            } else if scale == nil, line.hasPrefix("scale:") {
                scale = Int(line.dropFirst("scale:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        guard let level else { return nil }
        let divisor = scale.flatMap { $0 > 0 ? $0 : nil } ?? 100
        return RealBatteryReading(
            percent: level * 100 / divisor,
            isPowered: DeviceEffects.isPowered(fromBatteryDump: text)
        )
    }
}

// MARK: - Probe

/// Everything the Status bar rows read, in one `adb shell` round trip (0.41 s
/// on the API 37 emulator): the API level, both keys, the real battery and,
/// on API 31+, SystemUI's demo-mode and battery dumps.
public struct StatusBarDemoSnapshot: Sendable, Equatable {
    public var apiLevel: Int?
    /// `settings get global sysui_demo_allowed`; nil for `null` or empty.
    public var allowedRaw: String?
    /// `settings get global sysui_tuner_demo_on`; nil for `null` or empty.
    public var onRaw: String?
    public var realBattery: RealBatteryReading?
    /// nil below API 31, on a SystemUI without the dumpable, or when it did
    /// not answer.
    public var controller: DemoModeControllerReading?
    /// nil below API 33.
    public var systemUIBattery: DemoBatteryReading?

    public init(
        apiLevel: Int? = nil,
        allowedRaw: String? = nil,
        onRaw: String? = nil,
        realBattery: RealBatteryReading? = nil,
        controller: DemoModeControllerReading? = nil,
        systemUIBattery: DemoBatteryReading? = nil
    ) {
        self.apiLevel = apiLevel
        self.allowedRaw = allowedRaw
        self.onRaw = onRaw
        self.realBattery = realBattery
        self.controller = controller
        self.systemUIBattery = systemUIBattery
    }

    /// SystemUI reads both keys with `getInt(key, 0) != 0`.
    public var isAllowedKey: Bool { Int(allowedRaw ?? "0").map { $0 != 0 } ?? false }
    public var isOnKey: Bool { Int(onRaw ?? "0").map { $0 != 0 } ?? false }
    /// SystemUI's own answer where it reports one, else the key.
    public var isInDemoMode: Bool { controller?.isInDemoMode ?? isOnKey }
    public var reportsDemoMode: Bool { controller != nil }
    /// In demo mode with the gate off (entered by the broadcast alone and
    /// then the gate turned off, or `sysui_tuner_demo_on` = 1 written
    /// without the gate): SystemUI ignores every command, `exit` included,
    /// until `sysui_demo_allowed` is 1 again.
    public var isStuck: Bool { controller.map { $0.isInDemoMode && !$0.isAllowed } ?? false }
    /// Whether `notifications` has a receiver (none on API 37); true when
    /// SystemUI does not report its receivers.
    public var handlesNotifications: Bool { controller?.handles("notifications") ?? true }
    /// SystemUI's battery (API 33+) differs from the real one: demo mode
    /// left it behind, or a realign raced the exit. False where either is
    /// unread.
    public var isBatteryStale: Bool {
        guard let shown = systemUIBattery, let real = realBattery else { return false }
        return shown.level != real.percent || (real.isPowered.map { $0 != shown.pluggedIn } ?? false)
    }

    /// Whether a put-back should realign SystemUI's battery: where SystemUI
    /// reports it, when it is stale; else `whenUnread`. Never without a real
    /// battery to send.
    public func batteryNeedsRealign(whenUnread: Bool) -> Bool {
        guard realBattery != nil else { return false }
        return systemUIBattery == nil ? whenUnread : isBatteryStale
    }

    /// Whether this probe carries SystemUI's `DemoModeController` section
    /// where a caller expects it (`expectsController`, API 31+): a SystemUI
    /// that reported it before and prints nothing now did not answer.
    public func answers(expectingController expectsController: Bool) -> Bool {
        !expectsController || controller != nil || (apiLevel ?? 0) < StatusBarDemo.controllerMinimumAPI
    }

    enum Section: String, CaseIterable {
        case api
        case allowed
        case tunerOn = "tuner-on"
        case realBattery = "real-battery"
        case controller
        case systemUIBattery = "battery"

        var marker: String { "@@devicehubpro:sb:\(rawValue)" }
    }

    /// The probe, one shell line; every marker starts with `@@devicehubpro:sb:`.
    /// SystemUI's targeted dumps exist from API 31 (`DumpHandler` matches the
    /// target with `endsWith`), so they run only there.
    public static var probeScript: String {
        func mark(_ section: Section) -> String { "echo \(section.marker)" }
        let dump = "dumpsys activity service \(StatusBarDemo.systemUIService)"
        return [
            mark(.api), "getprop ro.build.version.sdk",
            mark(.allowed), "settings get global \(StatusBarDemo.allowedKey)",
            mark(.tunerOn), "settings get global \(StatusBarDemo.onKey)",
            mark(.realBattery), #"dumpsys battery 2>/dev/null | grep -E '^  ([A-Za-z]+ powered|level|scale): '"#,
            #"if [ "$(getprop ro.build.version.sdk)" -ge \#(StatusBarDemo.controllerMinimumAPI) ]; then "#
                + mark(.controller),
            "\(dump) DemoModeController 2>/dev/null | grep -E '^ +(isInDemoMode|isDemoModeAllowed)=|^ +[a-z]+ : \\['",
            mark(.systemUIBattery),
            "\(dump) BatteryController 2>/dev/null | grep -E '^ +m(Level|PluggedIn|PowerSave)='",
            "fi", "true",
        ].joined(separator: "; ")
    }

    public static func parse(_ output: String) -> StatusBarDemoSnapshot {
        let sections = ConditionsText.sections(from: output, markers: Section.allCases.map { ($0, $0.marker) })
        var snapshot = StatusBarDemoSnapshot()
        snapshot.apiLevel = sections[.api].flatMap { Int($0) }
        snapshot.allowedRaw = sections[.allowed].flatMap(ConditionsText.settingValue)
        snapshot.onRaw = sections[.tunerOn].flatMap(ConditionsText.settingValue)
        snapshot.realBattery = sections[.realBattery].flatMap(RealBatteryReading.parse)
        snapshot.controller = sections[.controller].flatMap(DemoModeControllerReading.parse)
        snapshot.systemUIBattery = sections[.systemUIBattery].flatMap(DemoBatteryReading.parse)
        return snapshot
    }
}

/// The keys as Device Hub Pro found them before its first write to a device, and
/// whether SystemUI was in demo mode then (someone else's demo mode, which
/// Device Hub Pro leaves on when it disconnects).
public struct StatusBarDemoOriginal: Sendable, Equatable, Codable {
    public var allowedRaw: String?
    public var onRaw: String?
    public var wasInDemoMode: Bool

    public init(allowedRaw: String?, onRaw: String?, wasInDemoMode: Bool) {
        self.allowedRaw = allowedRaw
        self.onRaw = onRaw
        self.wasInDemoMode = wasInDemoMode
    }

    /// Whether `snapshot`'s keys read as the put-back leaves them (the
    /// scripts end with `true`, so a refused `settings` write shows only
    /// here): the tuner key off — deleted or 0, which SystemUI itself writes
    /// when the gate closes in demo mode — and, where the put-back writes the
    /// gate (it was found off, or `closingTheGate(as:)`), the gate off.
    public func keysAreBack(in snapshot: StatusBarDemoSnapshot) -> Bool {
        guard !snapshot.isOnKey else { return false }
        return StatusBarDemoScript.allowedRestore(self) == nil || !snapshot.isAllowedKey
    }

    /// The keys a put-back leaves when it opens the gate itself for its
    /// broadcasts (`StatusBarDemoScript.needsGate`), from `snapshot`, the
    /// probe before that: a gate found on at Device Hub Pro's first write and
    /// closed since (Developer options ▸ Enable demo mode turned off) goes
    /// back to the closed value `snapshot` read, not to on. Otherwise the
    /// keys as found.
    public func closingTheGate(as snapshot: StatusBarDemoSnapshot) -> StatusBarDemoOriginal {
        guard StatusBarDemoScript.allowedRestore(self) == nil, !snapshot.isAllowedKey else { return self }
        var closed = self
        closed.allowedRaw = snapshot.allowedRaw
        return closed
    }
}

/// How long a write reads back before it gives up: up to `attempts` probes,
/// `delay` apart, and none started once `limit` has passed since the first
/// began (each probe is a round trip of 0.14–0.41 s on the API 37 emulator,
/// more on a phone).
public struct StatusBarDemoSettle: Sendable {
    public var attempts: Int
    public var delay: Duration
    public var limit: Duration?

    public init(attempts: Int, delay: Duration, limit: Duration? = nil) {
        self.attempts = attempts
        self.delay = delay
        self.limit = limit
    }

    /// About 3 s: the last probe starts within 3 s of the first.
    public static let standard = StatusBarDemoSettle(attempts: 20, delay: .milliseconds(150), limit: .seconds(3))
    public static let immediate = StatusBarDemoSettle(attempts: 1, delay: .zero)
}

/// Why a Status bar write did not take.
public enum StatusBarDemoError: Error, Equatable, CustomStringConvertible {
    /// `settings put global sysui_demo_allowed 1` failed on the device (its
    /// `settings` tool exits 255 with the reason on stderr), with the reason
    /// `refusalReason(standardError:)` keeps.
    case settingRefused(String)
    case notAllowed
    case notEntered
    case notInDemoMode
    /// SystemUI is still in demo mode after the exit's two tries.
    case notExited
    /// SystemUI left demo mode, but the keys did not read back as the
    /// put-back writes them.
    case keysNotRestored
    /// SystemUI reported `DemoModeController` before and printed nothing
    /// through the whole read-back.
    case systemUINotAnswering
    case batteryNotApplied(shown: DemoBatteryReading, expected: DemoBatteryReading)
    case invalidTime
    case invalidBatteryLevel

    public var description: String {
        switch self {
        case .settingRefused(let reason):
            return "The device refused settings put global sysui_demo_allowed 1: \(reason). Some phones let adb change settings only after an extra Developer options switch."
        case .notAllowed:
            return "SystemUI did not take sysui_demo_allowed=1 within about 3 s (dumpsys DemoModeController reports isDemoModeAllowed=false)."
        case .notEntered:
            return "SystemUI did not enter demo mode within about 3 s (dumpsys DemoModeController reports isInDemoMode=false). This status bar may not support demo mode."
        case .notInDemoMode:
            return "SystemUI is not in demo mode (sysui_demo_allowed was turned off, or SystemUI restarted), so it ignored the command."
        case .notExited:
            return "SystemUI is still in demo mode after exit."
        case .keysNotRestored:
            return "SystemUI left demo mode, but sysui_demo_allowed or sysui_tuner_demo_on did not go back (the device's settings tool refused the write)."
        case .systemUINotAnswering:
            return "SystemUI did not answer (dumpsys DemoModeController printed nothing; it may be restarting)."
        case .batteryNotApplied(let shown, let expected):
            return "SystemUI shows \(shown.label) instead of \(expected.label)."
        case .invalidTime:
            return "Enter a time from 00:00 to 23:59."
        case .invalidBatteryLevel:
            return "Enter a level from 0 to 100."
        }
    }

    /// The part of a refused `settings` write's stderr worth an alert: the
    /// first exception line (`java.lang.SecurityException: …`) — a
    /// SettingsProvider refusal arrives as "Exception occurred while
    /// executing 'put':" and the whole stack trace (`BasicShellCommandHandler`
    /// @android-15.0.0_r36 L95–107) — else the first line with text.
    public static func refusalReason(standardError: String) -> String {
        let lines = standardError
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let exception = lines.first { line in
            guard let colon = line.firstIndex(of: ":") else { return false }
            let name = line[..<colon]
            return name.contains(".") && !name.contains(" ") && (name.hasSuffix("Exception") || name.hasSuffix("Error"))
        }
        return exception ?? lines.first ?? ""
    }
}
