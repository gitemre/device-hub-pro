import CoreServices
import Darwin
import Foundation

/// Health signals from the simulator watcher.
public enum SimulatorWatcherHealth: Sendable, Equatable {
    /// `simctl list -j devices` failed N times in a row; the last snapshot stands.
    case listFailing(attempt: Int)
    /// The file-system trigger could not start: changes are found by the
    /// safety poll alone, so they surface up to one poll interval late.
    case degraded
}

public enum SimulatorWatcherEvent: Sendable {
    case snapshot(devices: [SimulatorDevice], degraded: Bool)
    case health(SimulatorWatcherHealth)
}

/// Watches a simulator device set and publishes device snapshots — the
/// simulator counterpart of `DeviceWatcher`.
///
/// CoreSimulator posts nothing a host process can observe, and `simctl
/// monitor` is undocumented, so the trigger is the file system: every device
/// is a folder `<set>/<UDID>/` holding `device.plist`, which CoreSimulator
/// rewrites when the device is created, renamed, booted (about 1.2 s in) or
/// shut down, and the folder disappears on delete. An FSEvents stream on the
/// set folder reports those changes; events deeper down (a running device
/// writes into `<UDID>/data/` constantly) are ignored. A relevant event arms
/// a debounce window, then one `simctl list -j devices` read produces the
/// snapshot, so a burst (create + boot) costs one read.
///
/// Triggers wait for the loop as flags, one per kind (file event, poll,
/// refresh), not as a queue: a read that hangs (CoreSimulatorService
/// restarting, each `list` waiting out its timeout) leaves at most one of
/// each pending, and no kind can push another out. A bounded queue did, and
/// a file event lost that way silenced the file-system trigger for good.
///
/// A safety poll backs the trigger up every `pollInterval`: it compares a
/// fingerprint of the set folder (device folders and their `device.plist`
/// modification times, read with `stat`, no process) and reads the list only
/// when the fingerprint changed or `fullRefreshInterval` has passed. A
/// `list -j devices` read costs about 80–90 ms of CPU, so polling the list
/// itself every 5 s would cost the idle watcher ~1.7 % of a core.
///
/// Snapshots are emitted only when a device's identity or state changed
/// (UDID, name, state, availability, device type, runtime); the sizes the
/// listing also carries change constantly on a booted device and do not
/// count. A failed read emits `.health(.listFailing)` and nothing else — an
/// empty list would read as "every simulator deleted".
public final class SimulatorWatcher: @unchecked Sendable {
    private let simctl: SimctlClient
    private let devicesDirectory: URL
    private let debounce: Duration
    private let pollInterval: Duration
    private let fullRefreshInterval: Duration
    private let usesFileEvents: Bool

    private let lock = NSLock()
    private var continuation: AsyncStream<SimulatorWatcherEvent>.Continuation?
    private var triggers: TriggerFlags?
    private var loopTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var fileEvents: FileEventTrigger?

    enum Trigger: Sendable, Hashable {
        case fileEvent
        case poll
        case refresh
    }

    /// The default device set's folder.
    public static var defaultDevicesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
    }

    /// Watches `simctl`'s device set: its `deviceSet` folder when it has one,
    /// otherwise the default set.
    public init(
        simctl: SimctlClient,
        devicesDirectory: URL? = nil,
        debounce: Duration = .milliseconds(300),
        pollInterval: Duration = .seconds(5),
        fullRefreshInterval: Duration = .seconds(30),
        usesFileEvents: Bool = true
    ) {
        self.simctl = simctl
        self.devicesDirectory = devicesDirectory ?? simctl.deviceSet ?? Self.defaultDevicesDirectory
        self.debounce = debounce
        self.pollInterval = pollInterval
        self.fullRefreshInterval = fullRefreshInterval
        self.usesFileEvents = usesFileEvents
    }

    deinit {
        fileEvents?.invalidate()
    }

    /// The event stream. One watcher drives one stream; `start()` publishes to it.
    public func events() -> AsyncStream<SimulatorWatcherEvent> {
        AsyncStream { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.stop() }
        }
    }

    public func start() {
        stop()
        let triggers = TriggerFlags()

        var fileEvents: FileEventTrigger?
        if usesFileEvents {
            fileEvents = FileEventTrigger(directory: devicesDirectory) {
                triggers.post(.fileEvent)
            }
        }
        let degraded = fileEvents == nil

        let pollInterval = self.pollInterval
        let pollTask = Task {
            while !Task.isCancelled {
                // Best effort: sleep only fails on cancellation; the loop re-checks it.
                try? await Task.sleep(for: pollInterval)
                triggers.post(.poll)
            }
        }
        let loopTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoop(triggers: triggers, degraded: degraded)
        }

        lock.lock()
        self.triggers = triggers
        self.fileEvents = fileEvents
        self.pollTask = pollTask
        self.loopTask = loopTask
        lock.unlock()

        if degraded {
            emit(.health(.degraded))
        }
        triggers.post(.refresh)
    }

    public func stop() {
        lock.lock()
        let loopTask = self.loopTask
        let pollTask = self.pollTask
        let fileEvents = self.fileEvents
        let triggers = self.triggers
        self.loopTask = nil
        self.pollTask = nil
        self.fileEvents = nil
        self.triggers = nil
        lock.unlock()
        fileEvents?.invalidate()
        triggers?.finish()
        pollTask?.cancel()
        loopTask?.cancel()
    }

    /// Reads the list now (after Device Hub Pro itself created, booted or deleted
    /// a device, say), without waiting for the file-system trigger.
    public func refresh() {
        lock.lock()
        let triggers = self.triggers
        lock.unlock()
        triggers?.post(.refresh)
    }

    // MARK: Loop

    private func runLoop(triggers: TriggerFlags, degraded: Bool) async {
        let clock = ContinuousClock()
        var lastEmitted: [DeviceKey]?
        var lastFingerprint: Fingerprint?
        var lastRead: ContinuousClock.Instant?
        var failures = 0

        for await _ in triggers.wakeUps {
            if Task.isCancelled { return }
            let pending = triggers.take()
            if pending.contains(.fileEvent) {
                // Coalesce the burst: triggers posted inside the window join
                // this read; those from the read onwards pend for the next.
                // Best effort: sleep only fails on cancellation, re-checked below.
                try? await Task.sleep(for: debounce)
                _ = triggers.take()
            } else if pending == [.poll] {
                let fingerprint = Fingerprint(directory: devicesDirectory)
                let due = lastRead.map { clock.now - $0 >= fullRefreshInterval } ?? true
                guard due || fingerprint != lastFingerprint || failures > 0 else { continue }
            } else if pending.isEmpty {
                // The wake-up of triggers an earlier `take()` already served.
                continue
            }
            if Task.isCancelled { return }

            let fingerprint = Fingerprint(directory: devicesDirectory)
            do {
                let devices = try await simctl.listDevices()
                lastRead = clock.now
                lastFingerprint = fingerprint
                let keys = devices.map(DeviceKey.init)
                if keys != lastEmitted || failures > 0 {
                    lastEmitted = keys
                    emit(.snapshot(devices: devices, degraded: degraded))
                }
                failures = 0
            } catch {
                if Task.isCancelled { return }
                failures += 1
                emit(.health(.listFailing(attempt: failures)))
            }
        }
    }

    /// Yields outside `lock`, as `DeviceWatcher` does: `stop()` takes `lock`
    /// and also runs as the stream's `onTermination`, inside the consumer's
    /// cancellation with that task's status-record lock held, while a `yield`
    /// that resumes the consumer needs that same lock. A yield under `lock`
    /// deadlocks against a consumer being cancelled. `start()` emits before
    /// it wakes the loop, which emits everything after, so the order needs
    /// no lock of its own.
    private func emit(_ event: SimulatorWatcherEvent) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(event)
    }

    /// Whether an FSEvents path (a directory, as directory-level streams
    /// report them) is the set folder itself or one device's folder. Deeper
    /// paths are a running device's data and never change the list.
    static func isRelevant(eventPath: String, devicesDirectory: String) -> Bool {
        let path = eventPath.hasSuffix("/") ? String(eventPath.dropLast()) : eventPath
        let root = devicesDirectory.hasSuffix("/") ? String(devicesDirectory.dropLast()) : devicesDirectory
        if path == root { return true }
        guard path.hasPrefix(root + "/") else { return false }
        let relative = path.dropFirst(root.count + 1)
        return !relative.contains("/")
    }
}

/// The loop's pending triggers, at most one of each kind. A burst of one
/// kind (FSEvents callbacks, polls behind a hanging read) is one pending
/// trigger, so it costs one list read, and nothing is ever dropped: the
/// wake-up stream buffers a single element, and `take()` returns every kind
/// posted since the last one.
private final class TriggerFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Set<SimulatorWatcher.Trigger> = []
    private let wakeUpContinuation: AsyncStream<Void>.Continuation
    let wakeUps: AsyncStream<Void>

    init() {
        (wakeUps, wakeUpContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Called from the FSEvents queue, the poll task and `refresh()`.
    func post(_ trigger: SimulatorWatcher.Trigger) {
        lock.lock()
        let inserted = pending.insert(trigger).inserted
        lock.unlock()
        // A kind already pending has a wake-up on the way, and the `take()`
        // after it will see this post too.
        if inserted {
            wakeUpContinuation.yield()
        }
    }

    /// The triggers posted since the last call, cleared.
    func take() -> Set<SimulatorWatcher.Trigger> {
        lock.lock()
        defer { lock.unlock() }
        let taken = pending
        pending = []
        return taken
    }

    func finish() {
        wakeUpContinuation.finish()
    }
}

/// The part of a device a snapshot consumer cares about.
private struct DeviceKey: Equatable {
    let udid: String
    let name: String
    let state: SimulatorState
    let isAvailable: Bool
    let deviceType: String?
    let runtime: String

    init(_ device: SimulatorDevice) {
        udid = device.udid
        name = device.name
        state = device.state
        isAvailable = device.isAvailable
        deviceType = device.deviceTypeIdentifier
        runtime = device.runtimeIdentifier
    }
}

/// The device folders of a set and their `device.plist` modification times.
private struct Fingerprint: Equatable {
    private var entries: [String: timespec] = [:]

    init(directory: URL) {
        // Best effort: an unreadable folder fingerprints as empty, which a
        // later readable one differs from.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            var info = stat()
            let plist = directory.appendingPathComponent(name).appendingPathComponent("device.plist").path
            if stat(plist, &info) == 0 {
                entries[name] = info.st_mtimespec
            }
        }
    }

    static func == (lhs: Fingerprint, rhs: Fingerprint) -> Bool {
        guard lhs.entries.count == rhs.entries.count else { return false }
        for (name, time) in lhs.entries {
            guard let other = rhs.entries[name],
                  other.tv_sec == time.tv_sec,
                  other.tv_nsec == time.tv_nsec
            else { return false }
        }
        return true
    }
}

/// A directory-level FSEvents stream on a device-set folder that calls
/// `onChange` for events on the folder itself or a device folder.
private final class FileEventTrigger: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "io.github.gitemre.devicehubpro.simulator-watcher.fsevents")
    private let roots: [String]
    private let onChange: @Sendable () -> Void
    private let lock = NSLock()

    init?(directory: URL, latency: TimeInterval = 0.2, onChange: @escaping @Sendable () -> Void) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        // FSEvents reports real paths (`/private/tmp/…` for `/tmp/…`), so
        // relevance is checked against both spellings.
        var roots = [directory.path]
        if let real = realpath(directory.path, nil) {
            roots.append(String(cString: real))
            free(real)
        }
        self.roots = roots
        self.onChange = onChange

        // The stream retains the trigger (released by `invalidate()`), so a
        // callback already queued when the watcher stops still finds it alive.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<FileEventTrigger>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<FileEventTrigger>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let trigger = Unmanaged<FileEventTrigger>.fromOpaque(info).takeUnretainedValue()
            let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            for index in 0..<count {
                let rescan = flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
                if rescan || trigger.isRelevant(String(cString: cPaths[index])) {
                    trigger.onChange()
                    return
                }
            }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        ) else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    private func isRelevant(_ path: String) -> Bool {
        roots.contains { SimulatorWatcher.isRelevant(eventPath: path, devicesDirectory: $0) }
    }

    /// Stops the stream and drops its reference to this trigger. Its owner
    /// must call it: until then the stream keeps the trigger alive.
    func invalidate() {
        lock.lock()
        let stream = self.stream
        self.stream = nil
        lock.unlock()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
