import Foundation

/// Wireless debugging pairing (spec §11.3). The phone's "Pair device with
/// pairing code" dialog shows an `IP:port` and a 6-digit code; `adb pair` runs
/// against that address. The device is then reachable on the *connect* port
/// its Wireless debugging screen shows — a random port on Android 11+, not
/// the pairing port and not 5555 — which adb also learns on its own through
/// mDNS (`_adb-tls-connect._tcp`). So the connect port is optional: when it
/// is left empty the endpoint is discovered (`AdbClient.pairAndConnect`).
public enum WirelessPairing {
    /// The legacy `adb tcpip` port. Android 11+'s pairing-code flow never uses
    /// it — its connect port is random — so it is *not* a connect-port
    /// prefill; kept for source compatibility and the `adb tcpip 5555` path.
    public static let defaultConnectPort = 5555

    /// The mDNS service type a paired device's connect endpoint is announced
    /// under.
    public static let connectServiceType = "_adb-tls-connect._tcp"

    public struct PairingRequest: Equatable, Sendable {
        public let host: String
        public let pairingPort: Int
        /// The Wireless debugging screen's port, when the user gave one; nil
        /// means "discover it".
        public let connectPort: Int?
        public let code: String

        public init(host: String, pairingPort: Int, connectPort: Int?, code: String) {
            self.host = host
            self.pairingPort = pairingPort
            self.connectPort = connectPort
            self.code = code
        }

        /// `host:port` as `adb pair` wants it (the phone's pairing dialog).
        public var pairingAddress: String { "\(host):\(pairingPort)" }

        /// `host:port` as `adb connect` wants it, when a connect port was given.
        public var connectAddress: String? { connectPort.map { "\(host):\($0)" } }
    }

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case emptyAddress
        case missingPort
        case invalidPairingPort
        case invalidConnectPort
        case invalidCode

        public var description: String {
            switch self {
            case .emptyAddress:
                return "Enter the phone's pairing address, e.g. 192.168.1.42:37000."
            case .missingPort:
                return "Include the pairing port — the phone shows it as IP:port, e.g. 192.168.1.42:37000."
            case .invalidPairingPort:
                return "The pairing port must be a number between 1 and 65535."
            case .invalidConnectPort:
                return "The connect port must be a number between 1 and 65535, or empty to find it automatically."
            case .invalidCode:
                return "Enter the 6-digit pairing code shown on the phone."
            }
        }
    }

    /// Validates the sheet's fields. An empty `connectPort` is valid and
    /// yields a request without one (discovered after pairing).
    public static func request(
        address: String,
        code: String,
        connectPort: String
    ) throws -> PairingRequest {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else { throw ValidationError.emptyAddress }

        // The last colon separates the port; bracketed IPv6 hosts
        // ("[fe80::1]:37000") keep their internal colons.
        guard let separator = trimmedAddress.lastIndex(of: ":") else {
            throw ValidationError.missingPort
        }
        let host = trimmedAddress[..<separator].trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw ValidationError.emptyAddress }

        let portText = trimmedAddress[trimmedAddress.index(after: separator)...]
            .trimmingCharacters(in: .whitespaces)
        guard let pairingPort = Int(portText), (1...65535).contains(pairingPort) else {
            throw ValidationError.invalidPairingPort
        }

        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCode.count == 6,
              trimmedCode.allSatisfy({ $0.isASCII && $0.isNumber })
        else {
            throw ValidationError.invalidCode
        }

        let trimmedConnectPort = connectPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedConnectPort: Int?
        if trimmedConnectPort.isEmpty {
            resolvedConnectPort = nil
        } else if let port = Int(trimmedConnectPort), (1...65535).contains(port) {
            resolvedConnectPort = port
        } else {
            throw ValidationError.invalidConnectPort
        }

        return PairingRequest(
            host: host,
            pairingPort: pairingPort,
            connectPort: resolvedConnectPort,
            code: trimmedCode
        )
    }

    // MARK: - Outcome

    /// How far `AdbClient.pairAndConnect` got. Pairing and connecting are
    /// separate steps with separate failures: a successful pair stores the
    /// keys on both sides even when the connect then fails, so the UI can say
    /// "Paired — now connect" instead of reporting the whole flow as failed.
    public enum Outcome: Equatable, Sendable {
        /// Paired and connected on `address` (given, or discovered via mDNS).
        case connected(address: String)
        /// Paired, but no connect endpoint was given or discovered in time.
        /// adb's mDNS auto-connect usually attaches the phone by itself
        /// shortly; otherwise the user enters the Wireless debugging port.
        case pairedAwaitingConnection
        /// Paired, but `adb connect` on `address` failed with `message`.
        case pairedConnectFailed(address: String, message: String)
        /// `adb pair` itself failed (wrong code, expired dialog, unreachable).
        case pairingFailed(message: String)

        /// True once the pairing step succeeded, whatever the connect did.
        public var isPaired: Bool {
            if case .pairingFailed = self { return false }
            return true
        }
    }

    // MARK: - mDNS

    /// One `adb mdns services` row: `instance<TAB>service<TAB>ip:port`.
    public struct MdnsService: Equatable, Sendable {
        /// The instance name, e.g. `adb-R58M12345AB-yXk7tu`.
        public let instance: String
        /// The service type without a trailing dot, e.g. `_adb-tls-connect._tcp`.
        public let type: String
        public let host: String
        public let port: Int

        public init(instance: String, type: String, host: String, port: Int) {
            self.instance = instance
            self.type = type
            self.host = host
            self.port = port
        }

        /// `host:port`, as `adb connect` wants it.
        public var address: String { "\(host):\(port)" }
    }

    /// Parses `adb mdns services` output: a `List of discovered mdns services`
    /// header, then `instance\tservice\tip:port` rows (the service type may
    /// carry a trailing dot on the Bonjour backend). Rows that do not parse
    /// are skipped.
    public static func mdnsServices(from output: String) -> [MdnsService] {
        var services: [MdnsService] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("List of"), !line.hasPrefix("*") else { continue }
            let tabbed = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            let columns = tabbed.count >= 3
                ? tabbed
                : line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard columns.count >= 3,
                  let endpoint = columns.last,
                  let separator = endpoint.lastIndex(of: ":"),
                  let port = Int(endpoint[endpoint.index(after: separator)...]),
                  (1...65535).contains(port)
            else { continue }
            let host = String(endpoint[..<separator])
            var type = columns[columns.count - 2]
            if type.hasSuffix(".") { type.removeLast() }
            let instance = columns[0..<(columns.count - 2)].joined(separator: " ")
            guard !host.isEmpty, !type.isEmpty, !instance.isEmpty else { continue }
            services.append(MdnsService(instance: instance, type: type, host: host, port: port))
        }
        return services
    }

    /// The connect endpoint a device at `host` announces, if any: the
    /// `_adb-tls-connect._tcp` service on that host. Never guesses across
    /// hosts — another phone's endpoint is not this one's.
    public static func connectEndpoint(forHost host: String, in services: [MdnsService]) -> String? {
        // Brackets off both sides: an IPv6 host may come bracketed from either.
        let brackets = CharacterSet(charactersIn: "[]")
        let wanted = host.trimmingCharacters(in: brackets)
        return services.first {
            $0.type == connectServiceType && $0.host.trimmingCharacters(in: brackets) == wanted
        }?.address
    }
}
