import Foundation
import Observation
import DeviceHubProKit

/// The Pair Device sheet's wireless pairing (spec §11.3): the attempt in
/// flight and the `adb pair`/`adb connect` flow behind it.
///
/// `AppModel` owns one as `pairing`; the Pair Device sheet and the tests call
/// it directly. It never reaches back into the model: a paired attempt refreshes the device list through `refresh`, and
/// reports through the status center.
@MainActor
@Observable
final class WirelessPairingController {
    /// True while the Pair Device sheet's `adb pair`/`adb connect` runs.
    private(set) var isPairingDevice = false
    /// Bumped for every pairing attempt and by `cancelPairing()`; a completed
    /// attempt only applies its result (busy state, refresh, status flash)
    /// while it is still the current one.
    private var pairingGeneration: UInt64 = 0

    private let adbClient: AdbClient?
    private let status: StatusCenter
    /// Refreshes the device list after a paired attempt. `AppModel` points it
    /// at its `refreshAndroid()` once its own init can capture it; tests pass
    /// a spy to `init`.
    @ObservationIgnored var refresh: @MainActor () async -> Void
    /// Told of every failed `adb connect` (address, message): the adb-server
    /// recovery reads "No route to host" as a sign the server is blocked.
    @ObservationIgnored var onConnectFailure: @MainActor (_ address: String, _ message: String) -> Void = { _, _ in }

    init(
        adbClient: AdbClient?,
        status: StatusCenter,
        refresh: @escaping @MainActor () async -> Void = {}
    ) {
        self.adbClient = adbClient
        self.status = status
        self.refresh = refresh
    }

    // MARK: - Wireless pairing

    /// Pairs and connects a device in wireless-debugging mode (spec §11.3)
    /// through `AdbClient.pairAndConnect`: `adb pair <pairing address>
    /// <code>`, then `adb connect` on the connect port the user gave (the
    /// Wireless debugging screen's IP address & Port — random on Android
    /// 11+, never the pairing port) or, when it is empty, on the endpoint the
    /// phone announces over mDNS. With `alreadyPaired` (the previous attempt
    /// paired but did not connect, and the code is spent) only the connect
    /// runs. The result tells the sheet what to show; a successful pair is
    /// never reported as a failed one.
    func pairWirelessDevice(
        address: String,
        code: String,
        connectPort: String,
        alreadyPaired: Bool = false
    ) async -> PairingAttemptResult {
        // A sheet cancelled before the task started must not flip the busy
        // state back on.
        guard !Task.isCancelled else { return .cancelled }
        guard let adbClient else {
            return .failed(AdbError.adbNotFound.description)
        }
        let request: WirelessPairing.PairingRequest
        do {
            request = try WirelessPairing.request(
                address: address,
                code: code,
                connectPort: connectPort
            )
        } catch {
            return .failed("\(error)")
        }

        pairingGeneration &+= 1
        let generation = pairingGeneration
        isPairingDevice = true
        defer {
            if pairingGeneration == generation { isPairingDevice = false }
        }
        let outcome: WirelessPairing.Outcome
        do {
            outcome = alreadyPaired
                ? try await Self.connectPairedDevice(request, adbClient: adbClient)
                : try await adbClient.pairAndConnect(request)
        } catch {
            // Both throw only CancellationError: the sheet is gone.
            return .cancelled
        }
        // A cancelled sheet must not apply the late result (refresh, flash).
        guard pairingGeneration == generation, !Task.isCancelled else { return .cancelled }
        if outcome.isPaired {
            // adb's own mDNS auto-connect may attach a paired phone even when
            // this connect did not, so the list is refreshed either way.
            await refresh()
            guard pairingGeneration == generation, !Task.isCancelled else { return .cancelled }
        }
        if case .connected(let connectedAddress) = outcome {
            status.flash("Paired \(connectedAddress)")
        }
        if case .pairedConnectFailed(let failedAddress, let message) = outcome {
            onConnectFailure(failedAddress, message)
        }
        return PairingAttemptResult(outcome, host: request.host)
    }

    // MARK: - QR pairing

    /// True while the Pair Nearby Device sheet waits for a phone to scan its
    /// QR code (or pairs the phone that did).
    private(set) var isWaitingForQR = false

    /// The QR flow of the Pair Nearby Device sheet (Android Studio's way):
    /// waits up to `scanTimeout` for the phone to announce the pairing
    /// service of `credentials`, pairs with the password, and connects to the
    /// same phone's connect service (`AdbClient.pairWithQR`). The device list
    /// is refreshed once the phone paired; a connected phone flashes.
    func pairWithQR(
        _ credentials: WirelessPairing.QRCredentials,
        scanTimeout: Duration = .seconds(120)
    ) async -> QRPairingResult {
        guard !Task.isCancelled else { return .cancelled }
        guard let adbClient else { return .attempt(.failed(AdbError.adbNotFound.description)) }
        pairingGeneration &+= 1
        let generation = pairingGeneration
        isWaitingForQR = true
        defer {
            if pairingGeneration == generation { isWaitingForQR = false }
        }
        let outcome: WirelessPairing.QROutcome
        do {
            outcome = try await adbClient.pairWithQR(credentials, scanTimeout: scanTimeout)
        } catch {
            // Only `CancellationError`: the sheet is gone or the tab changed.
            return .cancelled
        }
        guard pairingGeneration == generation, !Task.isCancelled else { return .cancelled }
        guard case .scanned(let host, let pairOutcome) = outcome else { return .notScanned }
        if pairOutcome.isPaired {
            await refresh()
            guard pairingGeneration == generation, !Task.isCancelled else { return .cancelled }
        }
        if case .connected(let address) = pairOutcome {
            status.flash("Paired \(address)")
        }
        if case .pairedConnectFailed(let failedAddress, let message) = pairOutcome {
            onConnectFailure(failedAddress, message)
        }
        return .attempt(PairingAttemptResult(pairOutcome, host: host))
    }

    /// Called when the pairing sheet is cancelled or dismissed: the in-flight
    /// attempt's result is ignored and a new attempt can start cleanly.
    func cancelPairing() {
        pairingGeneration &+= 1
        isPairingDevice = false
        isWaitingForQR = false
    }

    /// The connect half of `AdbClient.pairAndConnect` for a phone that is
    /// already paired: `adb connect` on the given port, else on the endpoint
    /// the phone announces over mDNS. Throws only `CancellationError`.
    static func connectPairedDevice(
        _ request: WirelessPairing.PairingRequest,
        adbClient: AdbClient,
        discoveryTimeout: Duration = .seconds(10)
    ) async throws -> WirelessPairing.Outcome {
        let address: String
        if let given = request.connectAddress {
            address = given
        } else if let discovered = try await adbClient.discoverConnectEndpoint(
            host: request.host,
            timeout: discoveryTimeout
        ) {
            address = discovered
        } else {
            return .pairedAwaitingConnection
        }
        do {
            let attached = try await adbClient.connectUnlessAttached(address: address, host: request.host)
            return .connected(address: attached)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .pairedConnectFailed(address: address, message: "\(error)")
        }
    }
}
