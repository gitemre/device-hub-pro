import Foundation

// MARK: - Data path

/// Which network carries the device's traffic: the transport of
/// ConnectivityService's default network. Speed and latency (`NetworkShaper`)
/// shape whichever interface the default route uses, Wi-Fi or mobile data;
/// the cellular rows (service, signal, meter) act on the modem only.
public enum DataPath: Sendable, Equatable {
    case mobileData
    case wifi
    /// Another transport (Ethernet, VPN, …), by its dump name.
    case other(String)
    /// No default network (airplane mode, or both radios off).
    case noNetwork

    public var label: String {
        switch self {
        case .mobileData: return "Mobile data"
        case .wifi: return "Wi-Fi"
        case .other(let transport): return transport.capitalized
        case .noNetwork: return "No network"
        }
    }
}

/// One `NetworkAgentInfo` line of `dumpsys connectivity`.
public struct NetworkAgent: Sendable, Equatable {
    public let id: Int
    /// `Transports: CELLULAR` (several are joined by `|`).
    public let transports: [String]
    /// `Capabilities: NOT_METERED&INTERNET&…`.
    public let capabilities: Set<String>
    public let interfaceName: String?

    public init(id: Int, transports: [String], capabilities: Set<String>, interfaceName: String?) {
        self.id = id
        self.transports = transports
        self.capabilities = capabilities
        self.interfaceName = interfaceName
    }

    public var isCellular: Bool { transports.contains("CELLULAR") }
}

/// ConnectivityService's view: the default network and every network agent.
public struct ConnectivityReading: Sendable, Equatable {
    /// nil when the dump says `none` (or the line is missing).
    public var defaultNetworkID: Int?
    /// Whether the dump carried the `Active default network` line at all.
    public var answered: Bool
    public var agents: [NetworkAgent]

    public init(defaultNetworkID: Int?, answered: Bool, agents: [NetworkAgent]) {
        self.defaultNetworkID = defaultNetworkID
        self.answered = answered
        self.agents = agents
    }

    public var defaultAgent: NetworkAgent? {
        defaultNetworkID.flatMap { id in agents.first { $0.id == id } }
    }

    /// The default network's transport; nil when the dump was unreadable.
    public var dataPath: DataPath? {
        guard answered else { return nil }
        guard let agent = defaultAgent else { return .noNetwork }
        if agent.transports.contains("CELLULAR") { return .mobileData }
        if agent.transports.contains("WIFI") { return .wifi }
        return .other(agent.transports.first ?? "unknown")
    }

    /// The mobile network agent, whether or not it is the default.
    public var cellularAgent: NetworkAgent? { agents.first(where: \.isCellular) }

    /// Whether mobile data is metered: `gsm meter off` adds only
    /// `TEMPORARILY_NOT_METERED` (never `NOT_METERED`), so this reads that
    /// capability. nil while no mobile network exists, where the modem's
    /// setting is not observable.
    public var isMobileDataMetered: Bool? {
        cellularAgent.map { !$0.capabilities.contains("TEMPORARILY_NOT_METERED") }
    }

    /// `dumpsys connectivity`, filtered to the `Active default network` line
    /// and the `NetworkAgentInfo` lines (the probe greps them on the device).
    public static func parse(_ text: String) -> ConnectivityReading {
        var defaultID: Int?
        var answered = false
        var agents: [NetworkAgent] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Active default network:") {
                answered = true
                let value = line.dropFirst("Active default network:".count)
                    .trimmingCharacters(in: .whitespaces)
                defaultID = Int(value)
            } else if line.hasPrefix("NetworkAgentInfo"), let agent = agent(from: line) {
                agents.append(agent)
            }
        }
        return ConnectivityReading(defaultNetworkID: defaultID, answered: answered, agents: agents)
    }

    /// One agent line: `network{103}`, and inside its `nc{[ … ]}` the
    /// `Transports:` and `Capabilities:` lists.
    static func agent(from line: String) -> NetworkAgent? {
        guard let id = ConditionsText.braced(after: "network{", in: line[...]).flatMap({ Int($0) }) else {
            return nil
        }
        let capabilitiesPart = line.range(of: "nc{").map { line[$0.upperBound...] } ?? line[...]
        let transports = ConditionsText.word(after: "Transports: ", in: capabilitiesPart)
            .map { $0.split(separator: "|").map(String.init) } ?? []
        let capabilities = ConditionsText.word(after: "Capabilities: ", in: capabilitiesPart)
            .map { Set($0.split(separator: "&").map(String.init)) } ?? []
        let interface = ConditionsText.word(after: "InterfaceName: ", in: line[...])
        return NetworkAgent(id: id, transports: transports, capabilities: capabilities, interfaceName: interface)
    }
}

// MARK: - Latency

/// The added round-trip latency, in milliseconds, uniformly random between
/// the minimum and the maximum. `NetworkShaper` applies it with `tc netem`
/// in the guest, half in each direction, to all traffic of the data path
/// (not just connection setup, which is all the emulator console's `network
/// delay` ever held). Active only when `0 < minimum <= maximum`.
public struct ConnectionLatency: Sendable, Hashable {
    public let minimumMs: Int
    public let maximumMs: Int

    public init(minimumMs: Int, maximumMs: Int) {
        self.minimumMs = minimumMs
        self.maximumMs = maximumMs
    }

    public static let off = ConnectionLatency(minimumMs: 0, maximumMs: 0)

    /// Whether the emulator actually delays connections at this setting.
    public var isActive: Bool { minimumMs > 0 && minimumMs <= maximumMs }

    public var rangeLabel: String {
        minimumMs == maximumMs ? "\(minimumMs) ms" : "\(minimumMs)–\(maximumMs) ms"
    }

    /// The longest custom latency Device Hub Pro writes (one minute): anything
    /// longer only makes connections time out.
    public static let customLimitMs = 60_000

    /// Validates a custom range typed by the user: whole milliseconds with
    /// `1 <= minimum <= maximum <= customLimitMs`; `0:500` or `500:200` delay
    /// nothing.
    public static func custom(minimum: String, maximum: String) -> Result<ConnectionLatency, LatencyInputError> {
        let trimmedMinimum = minimum.trimmingCharacters(in: .whitespaces)
        let trimmedMaximum = maximum.trimmingCharacters(in: .whitespaces)
        guard let low = Int(trimmedMinimum), let high = Int(trimmedMaximum) else {
            return .failure(.notANumber)
        }
        guard low >= 1 else { return .failure(.minimumBelowOne) }
        guard low <= high else { return .failure(.minimumAboveMaximum) }
        guard high <= customLimitMs else { return .failure(.aboveLimit(customLimitMs)) }
        return .success(ConnectionLatency(minimumMs: low, maximumMs: high))
    }
}

/// Why a typed custom latency was refused.
public enum LatencyInputError: Error, Equatable, CustomStringConvertible {
    case notANumber
    case minimumBelowOne
    case minimumAboveMaximum
    case aboveLimit(Int)

    public var description: String {
        switch self {
        case .notANumber: return "Enter whole milliseconds for both values."
        case .minimumBelowOne: return "The minimum must be at least 1 ms; 0 turns the delay off."
        case .minimumAboveMaximum: return "The minimum must not exceed the maximum."
        case .aboveLimit(let limit): return "The maximum can be at most \(limit) ms."
        }
    }
}

/// The emulator's named latency profiles (external/qemu
/// `android/network/constants.h`, `ANDROID_NETWORK_LIST_MODES`; the header
/// calls the numbers made up). GPRS and UMTS share a range, as do EDGE and
/// HSCSD, so one entry names both. HSDPA, LTE, EVDO and 5G are 0–0: no
/// delay, so they are not offered. `help network delay` lists nothing on
/// current emulators, hence the table.
public enum LatencyPreset: String, CaseIterable, Identifiable, Sendable {
    case off
    case gprs
    case edge
    case gsm

    public var id: String { rawValue }

    public var latency: ConnectionLatency {
        switch self {
        case .off: return .off
        case .gprs: return ConnectionLatency(minimumMs: 35, maximumMs: 200)
        case .edge: return ConnectionLatency(minimumMs: 80, maximumMs: 400)
        case .gsm: return ConnectionLatency(minimumMs: 150, maximumMs: 550)
        }
    }

    public var label: String {
        switch self {
        case .off: return "None"
        case .gprs: return "GPRS / UMTS · 35–200 ms"
        case .edge: return "EDGE / HSCSD · 80–400 ms"
        case .gsm: return "GSM · 150–550 ms"
        }
    }

    public static func matching(_ latency: ConnectionLatency) -> LatencyPreset? {
        // tc prints tenths of a millisecond, so a read-back is within 1 ms.
        allCases.first {
            abs($0.latency.minimumMs - latency.minimumMs) <= 1 && abs($0.latency.maximumMs - latency.maximumMs) <= 1
        }
    }
}

// MARK: - Cellular service

/// The two service states the modem produces distinctly for apps. The
/// console's `searching`, `denied` and `off` all read back as out of
/// service, like `unregistered`, and `emergency only` is never produced,
/// so they are not offered.
public enum CellServiceOption: String, CaseIterable, Identifiable, Sendable {
    case inService
    case noService

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .inService: return "In service"
        case .noService: return "No service"
        }
    }

    /// The `gsm data` / `gsm voice` state. The modem couples the two
    /// domains, so both are written.
    public var consoleState: String {
        switch self {
        case .inService: return "home"
        case .noService: return "unregistered"
        }
    }
}

/// `ServiceState` registration states (`mVoiceRegState` / `mDataRegState`).
public struct CellServiceReading: Sendable, Equatable {
    public let voiceState: Int
    public let voiceName: String?
    public let dataState: Int
    public let dataName: String?

    public init(voiceState: Int, voiceName: String?, dataState: Int, dataName: String?) {
        self.voiceState = voiceState
        self.voiceName = voiceName
        self.dataState = dataState
        self.dataName = dataName
    }

    /// `ServiceState.STATE_IN_SERVICE` / `STATE_OUT_OF_SERVICE`.
    static let inService = 0
    static let outOfService = 1

    /// The option this reading shows, or nil for any other combination
    /// (power off in airplane mode, emergency only, mixed domains).
    public var option: CellServiceOption? {
        if voiceState == Self.inService, dataState == Self.inService { return .inService }
        if voiceState == Self.outOfService, dataState == Self.outOfService { return .noService }
        return nil
    }

    /// `voice IN_SERVICE, data OUT_OF_SERVICE` for a state no option names.
    public var summary: String {
        "voice \(voiceName ?? "\(voiceState)"), data \(dataName ?? "\(dataState)")"
    }

    /// The `mServiceState={mVoiceRegState=0(IN_SERVICE), mDataRegState=…`
    /// line of `dumpsys telephony.registry`.
    public static func parse(_ line: String) -> CellServiceReading? {
        guard let voice = ConditionsText.registration(after: "mVoiceRegState=", in: line[...]),
              let data = ConditionsText.registration(after: "mDataRegState=", in: line[...])
        else { return nil }
        return CellServiceReading(voiceState: voice.code, voiceName: voice.name, dataState: data.code, dataName: data.name)
    }
}

// MARK: - Signal strength

/// The modem simulator's signal profiles (`gsm signal-profile 1..4`, a
/// quarter of its strength range each). The modem then weakens the signal
/// 5 % every 10 s and jumps back to full, so a profile lasts seconds; the
/// row reads the level Android reports instead of claiming the profile.
/// Profile 0 (0 %) is left out: the modem's loop jumps back to full at
/// 10 % or less, so it reads back as full signal at once (measured on API
/// 37: level 4, -44/-49 dBm). Profile 1 is the weakest the modem holds,
/// for a few seconds. The legacy `gsm signal <rssi>` answers OK and does
/// nothing on current modems, so it is not used.
public enum SignalProfile: Int, CaseIterable, Identifiable, Sendable {
    case weak = 1
    case moderate = 2
    case good = 3
    case full = 4

    public var id: Int { rawValue }

    public var label: String {
        "\(rawValue) · \(rawValue * 25)%"
    }
}

/// `SignalStrength.getLevel()` and the primary technology's power.
public struct SignalReading: Sendable, Equatable {
    /// 0 (none) … 4 (great).
    public let level: Int
    public let dbm: Int?

    public init(level: Int, dbm: Int?) {
        self.level = level
        self.dbm = dbm
    }

    public var label: String {
        if let dbm { return "Level \(level) · \(dbm) dBm" }
        return "Level \(level)"
    }

    /// `CellInfo.UNAVAILABLE`.
    static let unavailable = Int(Int32.max)

    /// The `mSignalStrength=SignalStrength:{mCdma=…,mGsm=…,…,mNr=…,primary=CellSignalStrengthNr}`
    /// line: the primary technology's level and power (NR `ssRsrp`, LTE
    /// `rsrp`, GSM `rssi`, WCDMA `rscp`, CDMA `cdmaDbm`). Without a
    /// `primary=` (older images) the strongest level wins.
    public static func parse(_ line: String) -> SignalReading? {
        let technologies: [(key: String, className: String, power: String)] = [
            ("mCdma=", "CellSignalStrengthCdma", "cdmaDbm"),
            ("mGsm=", "CellSignalStrengthGsm", "rssi"),
            ("mWcdma=", "CellSignalStrengthWcdma", "rscp"),
            ("mTdscdma=", "CellSignalStrengthTdscdma", "rscp"),
            ("mLte=", "CellSignalStrengthLte", "rsrp"),
            ("mNr=", "CellSignalStrengthNr", "ssRsrp"),
        ]
        let body = line[...]
        var readings: [(className: String, reading: SignalReading)] = []
        for technology in technologies {
            guard let segment = segment(of: technology.key, in: body) else { continue }
            // GSM prints `mLevel=0`; every other technology `level=0` or
            // `level = 4` (NR).
            guard let level = ConditionsText.integer(after: "level", in: segment)
                ?? ConditionsText.integer(after: "mLevel", in: segment)
            else { continue }
            let power = ConditionsText.integer(after: technology.power, in: segment)
                .flatMap { $0 == unavailable ? nil : $0 }
            readings.append((technology.className, SignalReading(level: level, dbm: power)))
        }
        if let primary = ConditionsText.word(after: "primary=", in: body)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "}")),
           let match = readings.first(where: { $0.className == primary }) {
            return match.reading
        }
        return readings.max { $0.reading.level < $1.reading.level }?.reading
    }

    /// The text of one technology's entry: from its key to the next
    /// technology key or `primary=`.
    private static func segment(of key: String, in body: Substring) -> Substring? {
        guard let start = body.range(of: key) else { return nil }
        let rest = body[start.upperBound...]
        let ends = [",mCdma=", ",mGsm=", ",mWcdma=", ",mTdscdma=", ",mLte=", ",mNr=", ",primary="]
            .compactMap { rest.range(of: $0)?.lowerBound }
        return rest[..<(ends.min() ?? rest.endIndex)]
    }
}

// MARK: - Emulator identity

/// Which emulator answers on a serial, as its console names it. Serials are
/// reused — the next emulator usually takes `emulator-5554` — so a change
/// Device Hub Pro has to undo later is recorded against this, never the serial:
/// - the console's own state (latency, registration, signal, meter) lives
///   in the emulator process and ends with it; `discoveryPath`, whose file
///   name carries the process id (`…/avd/running/pid_20284.ini`), names
///   that process;
/// - the Wi-Fi and mobile-data switches are guest settings on the AVD's
///   disk and outlast the process; `avdName` names that disk (an AVD runs
///   in one emulator at a time).
public struct EmulatorInstance: Sendable, Equatable {
    /// `avd name`.
    public let avdName: String
    /// `avd discoverypath`.
    public let discoveryPath: String

    public init(avdName: String, discoveryPath: String) {
        self.avdName = avdName
        self.discoveryPath = discoveryPath
    }
}

// MARK: - Probe

/// Everything the Network conditions rows read from the device in one
/// `adb shell` round trip, every poll: the default network and its agents
/// (`dumpsys connectivity`), the registration and signal state
/// (`dumpsys telephony.registry`), and the two radio settings the data-path
/// switch saves and restores. Both dumps are filtered on the device; the
/// console's `network status` is a separate read (`AdbClient`).
public struct NetworkConditionsSnapshot: Sendable, Equatable {
    public var apiLevel: Int?
    public var connectivity: ConnectivityReading
    public var cellService: CellServiceReading?
    public var signal: SignalReading?
    /// `settings get global wifi_on` (`0`–`3`), as the device stores it.
    public var wifiOn: String?
    /// `settings get global mobile_data` (`0` / `1`).
    public var mobileData: String?

    public init(
        apiLevel: Int? = nil,
        connectivity: ConnectivityReading = ConnectivityReading(defaultNetworkID: nil, answered: false, agents: []),
        cellService: CellServiceReading? = nil,
        signal: SignalReading? = nil,
        wifiOn: String? = nil,
        mobileData: String? = nil
    ) {
        self.apiLevel = apiLevel
        self.connectivity = connectivity
        self.cellService = cellService
        self.signal = signal
        self.wifiOn = wifiOn
        self.mobileData = mobileData
    }

    enum Section: String, CaseIterable {
        case api
        case connectivity
        case telephony
        case wifiOn = "wifi-on"
        case mobileData = "mobile-data"

        var marker: String { "@@devicehubpro:net:\(rawValue)" }
    }

    /// The probe, one shell line. Every marker starts with
    /// `@@devicehubpro:net:` so a stub adb can tell it from the other probes.
    public static var probeScript: String {
        func mark(_ section: Section) -> String { "echo \(section.marker)" }
        return [
            mark(.api), "getprop ro.build.version.sdk",
            mark(.connectivity),
            "dumpsys connectivity 2>/dev/null | grep -E '^Active default network|^  NetworkAgentInfo'",
            mark(.telephony),
            "dumpsys telephony.registry 2>/dev/null | grep -E '^    (mServiceState|mSignalStrength)='",
            mark(.wifiOn), "settings get global wifi_on",
            mark(.mobileData), "settings get global mobile_data",
            "true",
        ].joined(separator: "; ")
    }

    public static func parse(_ output: String) -> NetworkConditionsSnapshot {
        let sections = ConditionsText.sections(from: output, markers: Section.allCases.map { ($0, $0.marker) })
        var snapshot = NetworkConditionsSnapshot()
        snapshot.apiLevel = sections[.api].flatMap { Int($0) }
        if let connectivity = sections[.connectivity] {
            snapshot.connectivity = ConnectivityReading.parse(connectivity)
        }
        if let telephony = sections[.telephony] {
            // One line of each per phone; the first phone is the emulator's.
            let lines = telephony.components(separatedBy: .newlines)
            snapshot.cellService = lines.first { $0.contains("mServiceState=") }
                .flatMap(CellServiceReading.parse)
            snapshot.signal = lines.first { $0.contains("mSignalStrength=") }
                .flatMap(SignalReading.parse)
        }
        snapshot.wifiOn = sections[.wifiOn].flatMap(ConditionsText.settingValue)
        snapshot.mobileData = sections[.mobileData].flatMap(ConditionsText.settingValue)
        return snapshot
    }
}

// MARK: - Text helpers

/// Small scanners shared by the conditions parsers (string scanning keeps
/// the parsers free of non-Sendable regex state).
enum ConditionsText {
    /// Splits marker-delimited probe output into its sections, each trimmed.
    static func sections<Key: Hashable>(from output: String, markers: [(Key, String)]) -> [Key: String] {
        var result: [Key: [String]] = [:]
        var current: Key?
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let marker = markers.first(where: { $0.1 == line }) {
                current = marker.0
                result[marker.0] = []
                continue
            }
            guard let current else { continue }
            result[current, default: []].append(rawLine)
        }
        return result.mapValues {
            $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// A `settings get` answer: nil for an empty answer or `null` (unset).
    static func settingValue(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "null" ? nil : value
    }

    /// The text between `prefix` (which ends in `{`) and the next `}`.
    static func braced(after prefix: String, in text: Substring) -> String? {
        guard let start = text.range(of: prefix) else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.firstIndex(of: "}") else { return nil }
        return String(rest[..<end])
    }

    /// The run of non-blank characters after `prefix`.
    static func word(after prefix: String, in text: Substring) -> String? {
        guard let start = text.range(of: prefix) else { return nil }
        let word = text[start.upperBound...].prefix { !$0.isWhitespace && $0 != "," }
        return word.isEmpty ? nil : String(word)
    }

    /// The integer after `key` followed by `=` or ` = ` (`level = 4`,
    /// `level=0`, `ssRsrp = -54`). An occurrence of `key` inside a longer
    /// name (`parametersUseForLevel`, `csiRsrp`) is skipped: the character
    /// before it must not be a letter.
    static func integer(after key: String, in text: Substring) -> Int? {
        var searchStart = text.startIndex
        while let range = text.range(of: key, range: searchStart..<text.endIndex) {
            searchStart = range.upperBound
            if range.lowerBound > text.startIndex, text[text.index(before: range.lowerBound)].isLetter {
                continue
            }
            let rest = text[range.upperBound...].drop { $0 == " " }
            guard rest.first == "=" else { continue }
            if let value = leadingInteger(rest.dropFirst()) { return value }
        }
        return nil
    }

    /// The integer at the start of `text`, after blanks (`  0 ms` → 0).
    static func leadingInteger(_ text: Substring) -> Int? {
        let trimmed = text.drop { $0 == " " || $0 == "\t" }
        var digits = ""
        for character in trimmed {
            if character.isNumber || (digits.isEmpty && character == "-") {
                digits.append(character)
            } else {
                break
            }
        }
        return Int(digits)
    }

    /// `0(IN_SERVICE)` or `4 (APP CRASH(EXCEPTION))` after `key`: the code
    /// and the name in its (balanced) parentheses.
    static func registration(after key: String, in text: Substring) -> (code: Int, name: String?)? {
        guard let start = text.range(of: key) else { return nil }
        let rest = text[start.upperBound...]
        guard let code = leadingInteger(rest) else { return nil }
        guard let open = rest.firstIndex(of: "("),
              rest[..<open].allSatisfy({ $0.isNumber || $0 == "-" || $0 == " " })
        else { return (code, nil) }
        var depth = 0
        for index in rest[open...].indices {
            switch rest[index] {
            case "(":
                depth += 1
            case ")":
                depth -= 1
                if depth == 0 {
                    return (code, String(rest[rest.index(after: open)..<index]))
                }
            default:
                break
            }
        }
        return (code, nil)
    }
}
