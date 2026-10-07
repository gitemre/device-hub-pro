import Foundation
import DeviceHubProKit

/// The emulators' gRPC control ports: the port recorded for each emulator
/// serial, and the resolution of a serial whose port is not recorded yet.
///
/// `AppModel` owns one as `grpcPorts`. A boot and an attach to a running AVD
/// record ports; the watcher's snapshots, the teardown, a stop, a power-on
/// restart and a restarted adb server forget them, because an emulator that
/// comes back can serve another port. It holds no reference to the model:
/// the current emulator and the consoles' AVD names go through the hooks
/// below, which the model sets once it is built. Nothing on screen reads the
/// ports, so it is not observed.
@MainActor
final class GrpcPortService {
    private var grpcCache = GrpcPortCache()

    private let adbClient: AdbClient?

    /// The current emulator, whose process list the resolution matches the
    /// AVD against. Settings' custom binary path swaps it at run time, so it
    /// is asked for at every use and never kept. Nil (no emulator) until its
    /// owner sets it.
    var emulatorManagerProvider: @MainActor () -> EmulatorManager? = { nil }
    /// The AVD `device` runs, from its owner's per-transport cache or its
    /// console (`AppModel.avdName(of:)`); nil while the console does not
    /// answer.
    var consoleAvdName: @MainActor (_ device: AndroidDevice) async -> String? = { _ in nil }

    init(adbClient: AdbClient?) {
        self.adbClient = adbClient
    }

    // MARK: - Recorded ports

    /// The port recorded for `serial`, if any.
    func port(for serial: String) -> Int? {
        grpcCache.port(for: serial)
    }

    /// Records the port the emulator behind `serial` serves.
    func store(_ port: Int, for serial: String) {
        grpcCache.store(port, for: serial)
    }

    /// Forgets `serial`'s port.
    func invalidate(serial: String) {
        grpcCache.invalidate(serial: serial)
    }

    /// Forgets the port of every serial that is not in `present`.
    func invalidate(missingFrom present: Set<String>) {
        grpcCache.invalidate(missingFrom: present)
    }

    /// Forgets every port.
    func invalidateAll() {
        grpcCache.invalidateAll()
    }

    // MARK: - Resolution

    /// Why `resolveGrpcPort` found no port: the resolver's precise reason,
    /// or nil when there was nothing to ask (no adb or emulator binary).
    struct GrpcResolutionFailure: Error {
        let reason: String?
    }

    /// Resolves (and caches) the gRPC port of an emulator serial. Reports
    /// instead of surfacing: the caller decides whether the answer still
    /// matters (a cancelled attach must stay silent).
    func resolveGrpcPort(for device: AndroidDevice) async -> Result<Int, GrpcResolutionFailure> {
        guard let adbClient, let emulatorManager else { return .failure(GrpcResolutionFailure(reason: nil)) }
        if let cached = grpcCache.port(for: device.serial) { return .success(cached) }
        // The discovery file wins: it carries the JWT token for emulators
        // started by Android Studio's Device Manager (and registers it).
        let info = await EmulatorDiscovery.grpcInfo(serial: device.serial, adbClient: adbClient)
        // Best effort: a failed `ps` read just drops that ladder rung — the
        // resolution then fails closed instead of binding a stranger's port.
        // The VMs are the ones the emulator's process scope sees: every VM
        // on the Mac in the app, only its own in a test.
        let runningRead = try? await emulatorManager.runningEmulators()
        // A failed read is not "nothing runs": with no discovery file either,
        // nothing identifies the VM, so fail without caching an answer.
        if runningRead == nil, info == nil { return .failure(GrpcResolutionFailure(reason: nil)) }
        let running = runningRead ?? []
        // Best effort: no AVD name means no `ps` identity match (same fallback).
        let avdName = await avdName(of: device)
        var liveScanPorts: [Int] = []
        if GrpcPortResolver.needsScan(discovery: info, avdName: avdName, running: running) {
            // The emulator's default ports; none for a test's own-process
            // scope, which must not find a VM it did not start by probing.
            for port in emulatorManager.grpcScanPorts {
                // A cancelled lookup's answer is dropped below: stop probing.
                if Task.isCancelled { break }
                if await EmulatorProbe.status(port: port) != nil {
                    liveScanPorts.append(port)
                }
            }
        }
        let resolution = GrpcPortResolver.resolve(
            discovery: info,
            avdName: avdName,
            running: running,
            liveScanPorts: liveScanPorts
        )
        // A cancelled read answered nil above, which says nothing about the
        // emulator; do not cache or report what it produced.
        guard !Task.isCancelled else { return .failure(GrpcResolutionFailure(reason: nil)) }
        switch resolution {
        case .discovery(let port), .processMatch(let port), .scan(let port):
            grpcCache.store(port, for: device.serial)
            return .success(port)
        case .unresolved(let reason):
            return .failure(GrpcResolutionFailure(reason: reason))
        }
    }

    // MARK: - Shims

    // Its owner's emulator and console answers under the names the moved
    // call sites use, so their text is unchanged.

    private var emulatorManager: EmulatorManager? { emulatorManagerProvider() }

    private func avdName(of device: AndroidDevice) async -> String? {
        await consoleAvdName(device)
    }
}
