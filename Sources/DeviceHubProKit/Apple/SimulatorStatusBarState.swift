import Foundation

extension SimulatorBatteryState: Codable, Identifiable {
    public var id: String { rawValue }
}

extension SimulatorWiFiMode: Codable {}
extension SimulatorCellularMode: Codable {}
extension SimulatorDataNetwork: Codable {}

/// The status bar Device Hub Pro draws on a simulator: every field simctl's
/// `status_bar override` takes, sent together (`SimctlClient.overrideStatusBar`).
///
/// Device Hub Pro keeps this model itself. simctl applies its flags per field
/// group and one group can reset another (`--wifiMode` alone put the bars
/// back to 3; `--operatorName` alone was not stored), and `status_bar list`
/// answers in numeric codes that cannot tell `hide` from `wifi` (both 0).
/// The override is drawn only: apps keep reading the simulator's own battery
/// (−1, unknown) and network.
public struct SimulatorStatusBarState: Codable, Sendable, Equatable {
    /// `HH:MM` or `H:MM` (simctl also takes an ISO-8601 date with fractional
    /// seconds and `Z`, which sets the date; the Controls send a time).
    public var time: String
    public var dataNetwork: SimulatorDataNetwork
    public var wifiMode: SimulatorWiFiMode
    /// 0–3.
    public var wifiBars: Int
    public var cellularMode: SimulatorCellularMode
    /// 0–4.
    public var cellularBars: Int
    /// Not drawn on Dynamic Island iPhones while Wi-Fi shows (measured).
    public var operatorName: String
    public var batteryState: SimulatorBatteryState
    /// 0–100.
    public var batteryLevel: Int

    public init(
        time: String = "9:41",
        dataNetwork: SimulatorDataNetwork = .fiveG,
        wifiMode: SimulatorWiFiMode = .active,
        wifiBars: Int = 3,
        cellularMode: SimulatorCellularMode = .active,
        cellularBars: Int = 4,
        operatorName: String = "",
        batteryState: SimulatorBatteryState = .charged,
        batteryLevel: Int = 100
    ) {
        self.time = time
        self.dataNetwork = dataNetwork
        self.wifiMode = wifiMode
        self.wifiBars = wifiBars
        self.cellularMode = cellularMode
        self.cellularBars = cellularBars
        self.operatorName = operatorName
        self.batteryState = batteryState
        self.batteryLevel = batteryLevel
    }

    /// The whole set, in simctl's flag order.
    public var overrideArguments: [String] {
        [
            "--time", time,
            "--dataNetwork", dataNetwork.rawValue,
            "--wifiMode", wifiMode.rawValue,
            "--wifiBars", String(wifiBars),
            "--cellularMode", cellularMode.rawValue,
            "--cellularBars", String(cellularBars),
            "--operatorName", operatorName,
            "--batteryState", batteryState.rawValue,
            "--batteryLevel", String(batteryLevel),
        ]
    }

    /// The problems simctl would refuse (exit 22, "expected 0-100"), found
    /// before it runs.
    public enum Problem: Error, Equatable, CustomStringConvertible {
        case time(String)
        case wifiBars(Int)
        case cellularBars(Int)
        case batteryLevel(Int)

        public var description: String {
            switch self {
            case .time(let text): "The status bar time takes H:MM or HH:MM, not \(text)."
            case .wifiBars(let bars): "Wi-Fi bars go from 0 to 3, not \(bars)."
            case .cellularBars(let bars): "Cellular bars go from 0 to 4, not \(bars)."
            case .batteryLevel(let level): "The battery level goes from 0 to 100, not \(level)."
            }
        }
    }

    public func validate() throws {
        guard Self.isClockTime(time) else { throw Problem.time(time) }
        guard (0...3).contains(wifiBars) else { throw Problem.wifiBars(wifiBars) }
        guard (0...4).contains(cellularBars) else { throw Problem.cellularBars(cellularBars) }
        guard (0...100).contains(batteryLevel) else { throw Problem.batteryLevel(batteryLevel) }
    }

    /// `H:MM` or `HH:MM`, hours 0–23: the time grammar simctl was measured to
    /// take besides ISO-8601 (`9:41 AM` and `12:34:56` exit 22).
    public static func isClockTime(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              (1...2).contains(parts[0].count), parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1])
        else { return false }
        return (0...23).contains(hour) && (0...59).contains(minute)
    }

    /// The model a `status_bar list` shows, over `base` for what the list
    /// cannot say: an empty list is nil (no override). `hide` and `wifi`
    /// share the data-network code 0, so a 0 keeps `base`'s choice between
    /// them.
    public static func fromList(_ list: SimulatorStatusBarOverrides, over base: SimulatorStatusBarState) -> SimulatorStatusBarState? {
        guard !list.isEmpty else { return nil }
        var state = base
        if let time = list.time { state.time = time }
        if let code = list.dataNetworkCode {
            if code == 0 {
                if base.dataNetwork != .hide && base.dataNetwork != .wifi { state.dataNetwork = .wifi }
            } else if let network = SimulatorDataNetwork.allCases.first(where: { $0.listCode == code }) {
                state.dataNetwork = network
            }
        }
        if let mode = list.wifiMode { state.wifiMode = mode }
        if let bars = list.wifiBars { state.wifiBars = bars }
        if let mode = list.cellularMode { state.cellularMode = mode }
        if let bars = list.cellularBars { state.cellularBars = bars }
        if let name = list.operatorName { state.operatorName = name }
        if let battery = list.batteryState { state.batteryState = battery }
        if let level = list.batteryLevel { state.batteryLevel = level }
        return state
    }
}

/// The Status bar group's presets: Device Hub Pro's own sets, sent through simctl
/// (devicectl's `statusBar preset` names are close: screenshot, low-battery,
/// no-service, charging), so they work without devicectl too.
public enum SimulatorStatusBarPreset: String, CaseIterable, Identifiable, Sendable {
    case screenshot
    case lowBattery
    case noService
    case charging

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .screenshot: "Screenshot (9:41, full)"
        case .lowBattery: "Low battery"
        case .noService: "No service"
        case .charging: "Charging"
        }
    }

    /// The preset applied over `base` (the operator name is kept).
    public func applied(to base: SimulatorStatusBarState) -> SimulatorStatusBarState {
        var state = base
        switch self {
        case .screenshot:
            state.time = "9:41"
            state.dataNetwork = .fiveG
            state.wifiMode = .active
            state.wifiBars = 3
            state.cellularMode = .active
            state.cellularBars = 4
            state.batteryState = .charged
            state.batteryLevel = 100
        case .lowBattery:
            state.dataNetwork = .lte
            state.wifiMode = .active
            state.wifiBars = 1
            state.cellularMode = .active
            state.cellularBars = 1
            state.batteryState = .discharging
            state.batteryLevel = 5
        case .noService:
            state.dataNetwork = .hide
            state.wifiMode = .failed
            state.wifiBars = 0
            state.cellularMode = .notSupported
            state.cellularBars = 0
        case .charging:
            state.dataNetwork = .lte
            state.wifiMode = .active
            state.wifiBars = 2
            state.cellularMode = .active
            state.cellularBars = 3
            state.batteryState = .charging
            state.batteryLevel = 50
        }
        return state
    }

    /// The preset `state` matches, if any.
    public static func matching(_ state: SimulatorStatusBarState) -> SimulatorStatusBarPreset? {
        allCases.first { $0.applied(to: state) == state }
    }
}
