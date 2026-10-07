import Foundation

/// Folds the adb entries that are one physical device into one row.
///
/// A phone paired over Wi-Fi can be listed by adb several times at once: by
/// USB (`<ro.serialno>`), by the `ip:port` of an explicit `adb connect`, and
/// by the mDNS name adb's own auto-connect uses
/// (`adb-<ro.serialno>-<suffix>._adb-tls-connect._tcp`). Android Studio and
/// Device Hub show one device; so does this. The group key is `ro.serialno`,
/// which a USB serial and an mDNS name carry themselves and an `ip:port`
/// entry has to be asked for (`AndroidDeviceGrouper`).
///
/// One transport is the group's row: an online one beats an offline one, then
/// USB beats IP:port beats the mDNS name; the row's last transport sticks
/// while it stays online. The others are kept as alternates,
/// and every non-chosen serial (plus the transport the group's row used last
/// time, when it has since left adb) maps to the chosen one, so the
/// selection, the mirror and the reconnect episode follow the live transport.
public enum AndroidDeviceGrouping {
    public enum TransportKind: Int, Sendable, Comparable {
        case usb = 0
        case ipPort = 1
        case mdns = 2

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Result: Sendable, Equatable {
        /// The rows: one per physical device, emulators and ungrouped
        /// entries untouched, in the order of their first appearance.
        public var devices: [AndroidDevice]
        /// Every adb serial that is not its group's row → the row's serial.
        public var aliases: [String: String]
        /// Group key (`ro.serialno`) → serial of its chosen transport, to
        /// hand back as `previousChosen` next time.
        public var chosenByGroup: [String: String]
    }

    private static let mdnsSuffix = "._adb-tls-connect._tcp"

    public static func kind(ofSerial serial: String) -> TransportKind {
        if serial.hasSuffix(mdnsSuffix) || (serial.hasPrefix("adb-") && serial.contains("._adb-")) {
            return .mdns
        }
        if isIPPort(serial) { return .ipPort }
        return .usb
    }

    /// `192.168.1.101:41473` or `[fe80::1]:5555`.
    public static func isIPPort(_ serial: String) -> Bool {
        guard let colon = serial.lastIndex(of: ":"),
              let port = Int(serial[serial.index(after: colon)...]),
              (1...65535).contains(port)
        else { return false }
        let host = serial[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return !host.isEmpty && host.allSatisfy { $0.isHexDigit || $0 == "." || $0 == ":" }
    }

    /// The `ro.serialno` an mDNS name carries:
    /// `adb-<serialno>-<suffix>._adb-tls-connect._tcp` gives `<serialno>`.
    public static func serialno(fromMdnsName name: String) -> String? {
        guard name.hasPrefix("adb-"), let end = name.range(of: "._adb-") else { return nil }
        let instance = name[name.index(name.startIndex, offsetBy: 4)..<end.lowerBound]
        guard let dash = instance.lastIndex(of: "-") else { return nil }
        let serialno = String(instance[..<dash])
        return serialno.isEmpty ? nil : serialno
    }

    /// The `ro.serialno` of an mDNS instance name as `adb mdns services`
    /// prints it (`adb-<serialno>-<suffix>`, no service type).
    public static func serialno(fromMdnsInstance instance: String) -> String? {
        serialno(fromMdnsName: instance + mdnsSuffix)
    }

    /// The group key `serial` can be told from its own text: a USB serial is
    /// its `ro.serialno`, an mDNS name carries it, an `ip:port` and an
    /// emulator do not (nil).
    public static func selfDescribedSerialno(of serial: String) -> String? {
        if serial.hasPrefix("emulator-") { return nil }
        switch kind(ofSerial: serial) {
        case .usb: return serial
        case .mdns: return serialno(fromMdnsName: serial)
        case .ipPort: return nil
        }
    }

    /// Whether an entry still needs `ro.serialno` read from the phone to be
    /// grouped: an online `ip:port` entry.
    public static func needsSerialnoRead(_ device: AndroidDevice) -> Bool {
        !device.isEmulator && kind(ofSerial: device.serial) == .ipPort && device.isOnline
    }

    /// - Parameters:
    ///   - serialnos: `ro.serialno` by adb serial, for the `ip:port` entries
    ///     already read (`AndroidDeviceGrouper`).
    ///   - previousChosen: `Result.chosenByGroup` of the previous call.
    public static func group(
        _ devices: [AndroidDevice],
        serialnos: [String: String] = [:],
        previousChosen: [String: String] = [:]
    ) -> Result {
        var order: [String] = []
        var members: [String: [AndroidDevice]] = [:]
        for device in devices {
            let key: String
            if let serialno = selfDescribedSerialno(of: device.serial) ?? serialnos[device.serial] {
                key = "hw:" + serialno
            } else {
                key = "serial:" + device.serial
            }
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(device)
        }

        var rows: [AndroidDevice] = []
        var aliases: [String: String] = [:]
        var chosenByGroup: [String: String] = [:]
        for key in order {
            let group = members[key] ?? []
            guard key.hasPrefix("hw:") else {
                rows.append(contentsOf: group)
                continue
            }
            let hardware = String(key.dropFirst(3))
            let ranked = group.sorted { lhs, rhs in
                if lhs.isOnline != rhs.isOnline { return lhs.isOnline }
                let lk = kind(ofSerial: lhs.serial), rk = kind(ofSerial: rhs.serial)
                if lk != rk { return lk < rk }
                return lhs.serial < rhs.serial
            }
            // Sticky: a transport that is still online stays the row, so a
            // working mirror is never moved by a better transport appearing.
            let chosen = previousChosen[hardware].flatMap { previous in
                ranked.first { $0.serial == previous && $0.isOnline }
            } ?? ranked[0]
            let others = ranked.map(\.serial).filter { $0 != chosen.serial }
            for other in others { aliases[other] = chosen.serial }
            if let previous = previousChosen[hardware], previous != chosen.serial {
                aliases[previous] = chosen.serial
            }
            chosenByGroup[hardware] = chosen.serial
            // Details the chosen entry lacks come from its siblings (an
            // offline entry lists no model).
            func donor(_ keyPath: KeyPath<AndroidDevice, String?>) -> String? {
                chosen[keyPath: keyPath] ?? ranked.compactMap { $0[keyPath: keyPath] }.first
            }
            rows.append(AndroidDevice(
                serial: chosen.serial,
                state: chosen.state,
                model: donor(\.model),
                product: donor(\.product),
                device: donor(\.device),
                transportID: chosen.transportID,
                hardwareSerial: hardware,
                alternateSerials: Array(others)
            ))
        }
        for serial in chosenByGroup.values { aliases[serial] = nil }
        return Result(devices: rows, aliases: aliases, chosenByGroup: chosenByGroup)
    }
}

/// `AndroidDeviceGrouping` plus its memory: `ro.serialno` read once per
/// `ip:port` serial (`adb -s <serial> shell getprop ro.serialno`, cached) and
/// the transport each group's row used last.
public actor AndroidDeviceGrouper {
    private let adb: AdbClient?
    private var serialnos: [String: String] = [:]
    private var previousChosen: [String: String] = [:]

    public init(adb: AdbClient?) {
        self.adb = adb
    }

    /// Groups `raw`, reading `ro.serialno` of each online `ip:port` entry not
    /// read yet. A failed read is retried at the next snapshot. Only the
    /// watcher's stream `commit`s the chosen transports: a one-off list read
    /// (Refresh) must not swallow the "this row moved" fact the watcher's
    /// lifecycle still has to hear.
    public func group(_ raw: [AndroidDevice], commit: Bool = true) async -> AndroidDeviceGrouping.Result {
        if let adb {
            for device in raw where AndroidDeviceGrouping.needsSerialnoRead(device) && serialnos[device.serial] == nil {
                // Best effort: an unreadable phone stays its own row for now.
                if let output = try? await adb.shell(serial: device.serial, ["getprop", "ro.serialno"]) {
                    let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { serialnos[device.serial] = value }
                }
            }
        }
        let result = AndroidDeviceGrouping.group(raw, serialnos: serialnos, previousChosen: previousChosen)
        // Merged, not replaced: a phone with no transport in this snapshot
        // (USB gone, its Wi-Fi one not listed yet) keeps its last row, so the
        // next snapshot aliases the vanished serial to the new transport and
        // the selection and mirror follow it (pairing
        // wireless debugging can drop USB first, and the row would stay offline).
        if commit { previousChosen.merge(result.chosenByGroup) { $1 } }
        return result
    }
}
