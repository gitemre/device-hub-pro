import Foundation

/// The pairing-code flow on top of `pair`/`connect` (spec §11.3), with the
/// connect endpoint discovered through adb's mDNS browser when the user did
/// not enter one.
extension AdbClient {
    /// Services adb's mDNS browser currently sees (`adb mdns services`).
    public func mdnsServices() async throws -> [WirelessPairing.MdnsService] {
        WirelessPairing.mdnsServices(from: try await run(["mdns", "services"]))
    }

    /// Polls `adb mdns services` until the device at `host` announces its
    /// `_adb-tls-connect._tcp` endpoint, or `timeout` elapses (nil). A failed
    /// read counts as "not yet": the browser may still be starting.
    public func discoverConnectEndpoint(
        host: String,
        timeout: Duration = .seconds(10),
        pollInterval: Duration = .milliseconds(500)
    ) async throws -> String? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            // Best effort: a failed read is retried until the deadline.
            if let services = try? await mdnsServices(),
               let endpoint = WirelessPairing.connectEndpoint(forHost: host, in: services) {
                return endpoint
            }
            try Task.checkCancellation()
            guard clock.now < deadline else { return nil }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// The serial adb already lists online for the phone at `host`, if any:
    /// an `ip:port` entry on that host, or the entry adb's own mDNS
    /// auto-connect made (`adb-<serialno>-<suffix>._adb-tls-connect._tcp`, or
    /// the USB serial of the same `ro.serialno`) for an mDNS instance
    /// announced from that host. Used so a pairing flow does not connect a
    /// second time to a phone that is already attached. Waits up to `grace`
    /// for the auto-connect, but only while mDNS shows the phone's connect
    /// service (without it nothing is about to arrive).
    public func existingWirelessConnection(
        host: String,
        grace: Duration = .seconds(3),
        pollInterval: Duration = .milliseconds(500)
    ) async throws -> String? {
        let wanted = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: grace)
        while true {
            // Best effort: unreadable lists count as "nothing yet".
            let online = ((try? await listDevices()) ?? []).filter(\.isOnline)
            if let direct = online.first(where: {
                AndroidDeviceGrouping.isIPPort($0.serial)
                    && $0.serial.hasPrefix(wanted + ":")
            }) {
                return direct.serial
            }
            let announced = ((try? await mdnsServices()) ?? []).filter {
                $0.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) == wanted
            }
            let serialnos = Set(announced.compactMap { AndroidDeviceGrouping.serialno(fromMdnsInstance: $0.instance) })
            if let match = online.first(where: { device in
                AndroidDeviceGrouping.selfDescribedSerialno(of: device.serial).map(serialnos.contains) ?? false
            }) {
                return match.serial
            }
            try Task.checkCancellation()
            guard !announced.isEmpty, clock.now < deadline else { return nil }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// `connect(address:)`, unless the phone at `host` is already attached
    /// (`existingWirelessConnection`); the serial that carries it, either way.
    @discardableResult
    public func connectUnlessAttached(
        address: String,
        host: String,
        attachGrace: Duration = .seconds(3)
    ) async throws -> String {
        if let existing = try await existingWirelessConnection(host: host, grace: attachGrace) {
            return existing
        }
        try await connect(address: address)
        return address
    }

    /// Pairs with `request`'s pairing address, then connects: on the connect
    /// port the user gave, else on the endpoint the phone announces over mDNS
    /// (waiting up to `discoveryTimeout`). Each step's failure is reported as
    /// its own `WirelessPairing.Outcome`, so a successful pair is never
    /// reported as a failed flow. Throws only `CancellationError`.
    public func pairAndConnect(
        _ request: WirelessPairing.PairingRequest,
        discoveryTimeout: Duration = .seconds(10),
        attachGrace: Duration = .seconds(3)
    ) async throws -> WirelessPairing.Outcome {
        do {
            try await pair(address: request.pairingAddress, code: request.code)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .pairingFailed(message: "\(error)")
        }
        try Task.checkCancellation()

        let address: String
        if let given = request.connectAddress {
            address = given
        } else if let discovered = try await discoverConnectEndpoint(
            host: request.host,
            timeout: discoveryTimeout
        ) {
            address = discovered
        } else {
            return .pairedAwaitingConnection
        }

        do {
            let attached = try await connectUnlessAttached(address: address, host: request.host, attachGrace: attachGrace)
            return .connected(address: attached)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .pairedConnectFailed(address: address, message: "\(error)")
        }
    }
}
