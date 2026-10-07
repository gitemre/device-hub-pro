import Foundation

/// QR pairing for Android 11+ wireless debugging, the way Android Studio does
/// it (the Pair Nearby Device sheet's Android
/// path). The host invents a service name and a password and shows them as a
/// QR code; the phone ("Pair device with QR code") scans it and announces a
/// `_adb-tls-pairing._tcp` service under exactly that instance name; the host
/// then runs `adb pair <host:port> <password>` against it and connects to the
/// `_adb-tls-connect._tcp` service of the same host.
extension WirelessPairing {
    /// The mDNS service type a phone in pairing mode announces.
    public static let pairingServiceType = "_adb-tls-pairing._tcp"

    /// The secret the QR code carries. Fresh for every attempt.
    public struct QRCredentials: Equatable, Sendable {
        /// The mDNS instance name the phone will announce (`S:` in the code).
        public let serviceName: String
        /// The pairing password (`P:` in the code).
        public let password: String

        public init(serviceName: String, password: String) {
            self.serviceName = serviceName
            self.password = password
        }

        /// `WIFI:T:ADB;S:<service-name>;P:<password>;;`, the text the QR
        /// code encodes (the Wi-Fi QR format with the ADB type).
        public var payload: String {
            "WIFI:T:ADB;S:\(Self.escape(serviceName));P:\(Self.escape(password));;"
        }

        /// The Wi-Fi QR format escapes `\ ; , : "`; generated values never
        /// contain them, but a caller-supplied one might.
        private static func escape(_ text: String) -> String {
            var result = ""
            for character in text {
                if "\\;,:\"".contains(character) { result.append("\\") }
                result.append(character)
            }
            return result
        }
    }

    /// Fresh credentials: `studio-` plus ten letters or digits (Android
    /// Studio's naming) and a twelve-character password.
    public static func makeQRCredentials<Generator: RandomNumberGenerator>(
        using generator: inout Generator
    ) -> QRCredentials {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        func random(_ count: Int, _ generator: inout Generator) -> String {
            String((0..<count).map { _ in alphabet.randomElement(using: &generator)! })
        }
        let name = "studio-" + random(10, &generator)
        return QRCredentials(serviceName: name, password: random(12, &generator))
    }

    public static func makeQRCredentials() -> QRCredentials {
        var generator = SystemRandomNumberGenerator()
        return makeQRCredentials(using: &generator)
    }

    /// The pairing service the phone announced under `serviceName`, if any:
    /// only the `_adb-tls-pairing._tcp` service whose instance name is
    /// exactly this attempt's. Another phone in pairing mode is never matched.
    public static func pairingEndpoint(
        serviceName: String,
        in services: [MdnsService]
    ) -> MdnsService? {
        services.first { $0.type == pairingServiceType && $0.instance == serviceName }
    }

    /// How far a QR attempt got.
    public enum QROutcome: Equatable, Sendable {
        /// The code was not scanned before the wait ended.
        case notScanned
        /// Scanned: pairing and connecting ended as `outcome` says.
        case scanned(host: String, outcome: Outcome)
    }
}

extension AdbClient {
    /// Polls `adb mdns services` until the phone announces the pairing
    /// service named `serviceName` (the QR code was scanned), or `timeout`
    /// elapses (nil). A failed read counts as "not yet".
    public func discoverPairingService(
        serviceName: String,
        timeout: Duration,
        pollInterval: Duration = .milliseconds(700)
    ) async throws -> WirelessPairing.MdnsService? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if let services = try? await mdnsServices(),
               let found = WirelessPairing.pairingEndpoint(serviceName: serviceName, in: services) {
                return found
            }
            try Task.checkCancellation()
            guard clock.now < deadline else { return nil }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// The whole QR flow: waits for the phone to announce the pairing
    /// service of `credentials`, runs `adb pair <host:port> <password>`, then
    /// connects to the phone's `_adb-tls-connect._tcp` endpoint (same host).
    /// None of these commands addresses a device by serial: `pair`, `connect`
    /// and `mdns` are host-level, and only the endpoint the scanning phone
    /// announced is ever used. Throws only `CancellationError`.
    public func pairWithQR(
        _ credentials: WirelessPairing.QRCredentials,
        scanTimeout: Duration = .seconds(120),
        discoveryTimeout: Duration = .seconds(10),
        attachGrace: Duration = .seconds(3)
    ) async throws -> WirelessPairing.QROutcome {
        guard let service = try await discoverPairingService(
            serviceName: credentials.serviceName,
            timeout: scanTimeout
        ) else { return .notScanned }

        do {
            try await pair(address: service.address, code: credentials.password)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .scanned(host: service.host, outcome: .pairingFailed(message: "\(error)"))
        }
        try Task.checkCancellation()

        guard let address = try await discoverConnectEndpoint(
            host: service.host,
            timeout: discoveryTimeout
        ) else {
            return .scanned(host: service.host, outcome: .pairedAwaitingConnection)
        }
        do {
            let attached = try await connectUnlessAttached(address: address, host: service.host, attachGrace: attachGrace)
            return .scanned(host: service.host, outcome: .connected(address: attached))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .scanned(
                host: service.host,
                outcome: .pairedConnectFailed(address: address, message: "\(error)")
            )
        }
    }
}
