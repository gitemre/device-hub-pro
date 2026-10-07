import Foundation
import Synchronization

/// Holds the phone's CoreDevice tunnel open while fast input runs.
///
/// The tunnel is a lease of about ten seconds that only a running CoreDevice
/// client renews. One resident `devicectl` child is that client: it observes a
/// notification name nobody ever posts (a fresh random one), which keeps the
/// lease alive without changing anything on the phone. Its session ends after
/// `sessionTimeout`, so a successor is started `restartLead` seconds before
/// that and the old child is ended once the successor runs.
///
/// This is the only place that builds this one `devicectl` argument shape
/// (`argv(...)`: HELP-DERIVED Xcode 27.0 (27A266a), `devicectl device
/// notification observe -h`; `--session-timeout` must be below `--timeout`).
/// `DevicectlPhysicalClient` keeps refusing the command word for everything else.
public actor TunnelLeaseKeeper: FastInputLease {
    public struct Timing: Sendable, Equatable {
        /// devicectl's `--session-timeout`, in seconds.
        public var sessionTimeout = 300
        /// The successor starts this many seconds before the session ends.
        public var restartLead = 30
        /// A failed restart is retried after this many seconds.
        public var retryDelay = 5

        public init() {}
    }

    private let devicectlURL: URL
    private let coreDeviceIdentifier: String
    private let developerDirectory: URL?
    private let launcher: any FastInputChildLauncher
    private let timing: Timing
    private let sleep: @Sendable (Duration) async throws -> Void
    private let makeName: @Sendable () -> String
    private let onFailure: (@Sendable (FastInputError) -> Void)?
    private let children = Mutex<[any FastInputChild]>([])
    private var rotation: Task<Void, Never>?
    private var currentChild: (any FastInputChild)?
    private var stopped = false

    public init(
        devicectlURL: URL,
        coreDeviceIdentifier: String,
        developerDirectory: URL? = nil,
        launcher: any FastInputChildLauncher,
        timing: Timing = Timing(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = FastInputClock.sleep,
        makeName: @escaping @Sendable () -> String = { "devicehubpro-lease-" + UUID().uuidString.lowercased() },
        onFailure: (@Sendable (FastInputError) -> Void)? = nil
    ) {
        self.devicectlURL = devicectlURL
        self.coreDeviceIdentifier = coreDeviceIdentifier
        self.developerDirectory = developerDirectory
        self.launcher = launcher
        self.timing = timing
        self.sleep = sleep
        self.makeName = makeName
        self.onFailure = onFailure
    }

    /// The child's argument list, or nil when a value is not plain enough
    /// (a device that is not a UUID, a name with anything but letters, digits
    /// and dashes, a session timeout that is not below the overall one).
    static func argv(coreDeviceIdentifier: String, name: String, sessionTimeout: Int) -> [String]? {
        guard UUID(uuidString: coreDeviceIdentifier) != nil,
              !name.isEmpty, name.count <= 80,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              sessionTimeout >= 10, sessionTimeout <= 3600
        else { return nil }
        return [
            "device", "notification", "observe",
            "--device", coreDeviceIdentifier,
            "--name", name,
            "--session-timeout", String(sessionTimeout),
            "--timeout", String(sessionTimeout + 5),
            "--quiet",
        ]
    }

    private func launchChild() throws -> any FastInputChild {
        guard let arguments = Self.argv(
            coreDeviceIdentifier: coreDeviceIdentifier,
            name: makeName(),
            sessionTimeout: timing.sessionTimeout
        ) else { throw FastInputError.leaseFailed("bad lease arguments") }
        let environment = developerDirectory.map { ["DEVELOPER_DIR": $0.path] }
        let child = try launcher.launch(
            executable: devicectlURL,
            arguments: arguments,
            environment: environment,
            wantsLines: false
        )
        children.withLock { $0.append(child) }
        FastInputTermination.register(child)
        return child
    }

    public func start() async throws {
        guard rotation == nil, !stopped else { return }
        currentChild = try launchChild()
        let waitSeconds = max(1, timing.sessionTimeout - timing.restartLead)
        let retrySeconds = max(1, timing.retryDelay)
        let sleep = self.sleep
        rotation = Task { [weak self] in
            var wait = waitSeconds
            while !Task.isCancelled {
                do { try await sleep(.seconds(wait)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                wait = await self.rotate() ? waitSeconds : retrySeconds
            }
        }
    }

    /// Starts the successor and ends the old child; false when the successor
    /// could not start (the old child stays, and the failure is reported).
    private func rotate() -> Bool {
        guard !stopped, let old = currentChild else { return true }
        do {
            let next = try launchChild()
            old.terminate()
            FastInputTermination.unregister(old)
            children.withLock { list in list.removeAll { $0 === old } }
            currentChild = next
            return true
        } catch {
            onFailure?((error as? FastInputError) ?? .leaseFailed("restart failed"))
            return false
        }
    }

    public func stop() {
        stopped = true
        rotation?.cancel()
        rotation = nil
        terminateNow()
    }

    public nonisolated func terminateNow() {
        let running = children.withLock { list -> [any FastInputChild] in
            defer { list.removeAll() }
            return list
        }
        for child in running {
            child.terminate()
            FastInputTermination.unregister(child)
        }
    }
}
